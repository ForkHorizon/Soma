#!/usr/bin/env python3
"""Prompt language optimization for Soma packets.

The optimizer normalizes non-English task intent to English while preserving
paths, symbols, code, JSON, URLs, and shell-like fragments exactly. It is
metadata-only for logs: callers receive hashes and counts, not raw originals.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import time
import urllib.request
from dataclasses import dataclass
from typing import Any

from token_calculator import estimate_tokens


TARGET_LANGUAGE = "en"
PLACEHOLDER_PREFIX = "SOMAPROTECTED"


@dataclass(frozen=True)
class ProtectedPrompt:
    text: str
    spans: list[str]


def _sha(text: str) -> str:
    return "sha256:" + hashlib.sha256((text or "").encode("utf-8", errors="replace")).hexdigest()


def detect_language(text: str) -> str:
    """Small deterministic detector: enough to catch Russian/Cyrillic prompts."""
    if not text.strip():
        return "unknown"
    cyrillic = len(re.findall(r"[\u0400-\u04FF]", text))
    latin = len(re.findall(r"[A-Za-z]", text))
    if cyrillic:
        return "ru"
    non_ascii_letters = len(re.findall(r"[^\W\d_A-Za-z]", text, flags=re.UNICODE))
    if non_ascii_letters > max(6, latin // 3):
        return "non_en"
    return "en"


def _span_patterns() -> list[re.Pattern[str]]:
    return [
        re.compile(r"```.*?```", re.DOTALL),
        re.compile(r"`[^`\n]+`"),
        re.compile(r"https?://[^\s)]+"),
        re.compile(r"(?<!\w)/(?:[A-Za-z0-9._\-]+/)+[A-Za-z0-9._\-]+"),
        re.compile(r"(?:^|\s)(?:\./|\../)(?:[A-Za-z0-9._\-]+/)*[A-Za-z0-9._\-]+\.[A-Za-z0-9._\-]+"),
        re.compile(r"\b[A-Za-z0-9_./-]+\.(?:swift|py|ts|tsx|js|jsx|go|rs|cpp|cc|h|hpp|java|kt|php|rb|json|jsonl|yaml|yml|toml|md|txt)\b"),
        re.compile(r"\b(?:[A-Z][A-Za-z0-9_]{2,})(?:\.[A-Za-z0-9_]+)?\b"),
        re.compile(r"\{(?:[^{}]|\{[^{}]*\})*\}", re.DOTALL),
        re.compile(r"(?m)^\s*(?:git|rg|sed|find|grep|python3?|xcodebuild|codex|gemini|npm|pnpm|yarn|swift|go|cargo)\b.*$"),
        re.compile(r"(?m)^\s*(?:at\s+|File\s+\"|Traceback\b|[A-Za-z_][A-Za-z0-9_]*Error:).*$"),
    ]


def protect_spans(text: str) -> ProtectedPrompt:
    spans: list[tuple[int, int]] = []
    for pattern in _span_patterns():
        for match in pattern.finditer(text):
            start, end = match.span()
            if start == end:
                continue
            if any(not (end <= old_start or start >= old_end) for old_start, old_end in spans):
                continue
            spans.append((start, end))
    spans.sort()
    protected_values: list[str] = []
    parts: list[str] = []
    cursor = 0
    for index, (start, end) in enumerate(spans):
        parts.append(text[cursor:start])
        protected_values.append(text[start:end])
        parts.append(f"{PLACEHOLDER_PREFIX}{index}")
        cursor = end
    parts.append(text[cursor:])
    return ProtectedPrompt("".join(parts), protected_values)


def restore_spans(text: str, spans: list[str]) -> str:
    restored = text
    for index, value in enumerate(spans):
        restored = restored.replace(f"{PLACEHOLDER_PREFIX}{index}", value)
    return restored


def _cyrillic_count(text: str) -> int:
    return len(re.findall(r"[\u0400-\u04FF]", text or ""))


def _local_ollama_translate(text: str, model: str, timeout: float) -> str:
    prompt = (
        "Translate the user's software engineering task to concise English. "
        f"Preserve placeholders like {PLACEHOLDER_PREFIX}0 exactly. "
        "Do not add commentary. Return only the translated task.\n\n"
        f"Task:\n{text}"
    )
    payload = {
        "model": model,
        "think": False,
        "stream": False,
        "messages": [
            {"role": "system", "content": "You are a precise technical translator."},
            {"role": "user", "content": prompt},
        ],
        "options": {"temperature": 0.0, "num_predict": 512},
    }
    request = urllib.request.Request(
        "http://127.0.0.1:11434/api/chat",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    start = time.monotonic()
    response_text = ""
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            response_text = response.read().decode("utf-8")
        decoded = json.loads(response_text)
        content = decoded.get("message", {}).get("content", "")
        if not isinstance(content, str) or not content.strip():
            raise RuntimeError("empty translation response")
        _log_local_translation_call(
            model=model,
            status="ok",
            duration_ms=(time.monotonic() - start) * 1000,
            request_payload=payload,
            response_text=response_text,
        )
        return content.strip()
    except Exception as exc:
        _log_local_translation_call(
            model=model,
            status="error",
            duration_ms=(time.monotonic() - start) * 1000,
            request_payload=payload,
            response_text=response_text,
            error=str(exc),
        )
        raise


def _log_local_translation_call(
    *,
    model: str,
    status: str,
    duration_ms: float,
    request_payload: dict[str, Any],
    response_text: str = "",
    error: str | None = None,
) -> None:
    try:
        from soma_logger import log_mcp_event

        messages = request_payload.get("messages") or []
        input_text = json.dumps(messages, default=str)
        log_mcp_event(
            event="local_model_call",
            status=status,
            duration_ms=duration_ms,
            input_tokens=estimate_tokens(input_text, "local"),
            output_tokens=estimate_tokens(response_text or "", "local"),
            error=error,
            project_root=os.environ.get("SOMA_PROJECT_ROOT"),
            extra={
                "local_model_provider": "ollama",
                "local_model": model,
                "local_model_stage": "translation",
                "local_model_json_mode": False,
                "local_model_num_predict": request_payload.get("options", {}).get("num_predict"),
                "local_model_message_count": len(messages),
            },
        )
    except Exception:
        pass


def _free_cloud_translate(text: str, timeout: float) -> str:
    """Optional free endpoint hook. Disabled unless SOMA_FREE_TRANSLATION_URL is set."""
    endpoint = os.environ.get("SOMA_FREE_TRANSLATION_URL", "").strip()
    if not endpoint:
        raise RuntimeError("free cloud translation endpoint is not configured")
    payload = json.dumps({"q": text, "source": "auto", "target": "en", "format": "text"}).encode("utf-8")
    request = urllib.request.Request(endpoint, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        decoded = json.loads(response.read().decode("utf-8"))
    translated = decoded.get("translatedText") or decoded.get("translation") or decoded.get("text")
    if not isinstance(translated, str) or not translated.strip():
        raise RuntimeError("empty cloud translation response")
    return translated.strip()


def _compute_metadata(
    *,
    original: str,
    normalized: str,
    source_language: str,
    status: str,
    engine: str | None,
    protected_count: int,
    warning: str | None = None,
    model_profile: str = "gpt-5.5",
) -> dict[str, Any]:
    original_tokens = estimate_tokens(original or "", model_profile)
    normalized_tokens = estimate_tokens(normalized or "", model_profile)
    saved = max(0, original_tokens - normalized_tokens)
    metadata: dict[str, Any] = {
        "status": status,
        "source_language": source_language,
        "target_language": TARGET_LANGUAGE,
        "engine": engine,
        "original_prompt_tokens": original_tokens,
        "normalized_prompt_tokens": normalized_tokens,
        "saved_tokens": saved,
        "savings_pct": round(100 * saved / max(original_tokens, 1), 1),
        "protected_spans_count": protected_count,
        "original_prompt_hash": _sha(original),
    }
    if warning:
        metadata["warning"] = warning[:300]
    return metadata


def optimize_prompt_language(goal: str, model_profile: str = "gpt-5.5") -> tuple[str, dict[str, Any]]:
    """Return the agent-facing English goal plus language optimization metadata."""
    enabled = os.environ.get("SOMA_TRANSLATION_ENABLED", "1").lower() not in {"0", "false", "no"}
    source_language = detect_language(goal)
    if not enabled:
        return goal, _compute_metadata(
            original=goal,
            normalized=goal,
            source_language=source_language,
            status="disabled",
            engine=None,
            protected_count=0,
            model_profile=model_profile,
        )
    if source_language == "en":
        return goal, _compute_metadata(
            original=goal,
            normalized=goal,
            source_language=source_language,
            status="original_english",
            engine=None,
            protected_count=0,
            model_profile=model_profile,
        )

    protected = protect_spans(goal)
    provider = os.environ.get("SOMA_TRANSLATION_PROVIDER", "local").lower().strip()
    timeout = float(os.environ.get("SOMA_TRANSLATION_TIMEOUT", "8") or 8)
    translator_model = os.environ.get("SOMA_TRANSLATOR_MODEL") or os.environ.get("SOMA_RANKER_MODEL") or os.environ.get("SOMA_LOCAL_MODEL") or "gemma4:e4b"

    try:
        if provider == "local":
            translated_protected = _local_ollama_translate(protected.text, translator_model, timeout)
            engine = f"local:{translator_model}"
        elif provider == "free_cloud":
            translated_protected = _free_cloud_translate(protected.text, timeout)
            engine = "free_cloud"
        else:
            raise RuntimeError(f"unsupported translation provider: {provider}")
        normalized = restore_spans(translated_protected, protected.spans).strip()
        if not normalized or _cyrillic_count(normalized) >= max(2, _cyrillic_count(goal) // 2):
            raise RuntimeError("translation did not sufficiently normalize Cyrillic text")
        return normalized, _compute_metadata(
            original=goal,
            normalized=normalized,
            source_language=source_language,
            status="translated",
            engine=engine,
            protected_count=len(protected.spans),
            model_profile=model_profile,
        )
    except Exception as exc:
        return goal, _compute_metadata(
            original=goal,
            normalized=goal,
            source_language=source_language,
            status="failed_fallback",
            engine=f"{provider}:{translator_model}" if provider == "local" else provider,
            protected_count=len(protected.spans),
            warning=str(exc),
            model_profile=model_profile,
        )


def log_fields(metadata: dict[str, Any] | None) -> dict[str, Any]:
    if not isinstance(metadata, dict):
        return {}
    return {
        "source_language": metadata.get("source_language"),
        "translation_status": metadata.get("status"),
        "translation_engine": metadata.get("engine"),
        "prompt_saved_tokens": metadata.get("saved_tokens"),
        "prompt_savings_pct": metadata.get("savings_pct"),
        "protected_spans_count": metadata.get("protected_spans_count"),
    }

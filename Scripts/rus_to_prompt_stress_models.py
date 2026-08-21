from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from rus_to_prompt_confidence_semantics import confidence_value as semantic_confidence_value


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Soma"))

from soma_language_optimizer_core import is_deepseek_stage_model  # noqa: E402

DEFAULT_CONFIDENCE_REASONING_EFFORT = "medium"
DEFAULT_CODEX_STAGE_REASONING_EFFORT = "medium"
DEFAULT_LOCAL_CONFIDENCE_MODELS = ["qwen3:30b-a3b", "qwen3-coder:30b-a3b-q4_K_M"]
DEFAULT_HYBRID_LOCAL_CONFIDENCE_THRESHOLD = 0.80
DEFAULT_HYBRID_DISAGREEMENT_THRESHOLD = 0.15
PROGRESS_PREFIX = "SOMA_PROGRESS "
TRANSLATION_ONLY_ANALYZER_MODEL = "translation-only"
CODEX_STAGE_MODELS = {
    "gpt-5.5",
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5.3-codex",
    "gpt-5.3-codex-spark",
    "gpt-5.2",
    "gpt-5-mini",
    "o4-mini",
    "codex-auto-review",
}
GEMINI_STAGE_MODELS = {
    "gemini-3-pro-preview",
    "gemini-3.1-pro-preview",
    "gemini-3.1-pro-preview-customtools",
    "gemini-3-flash-preview",
    "gemini-3.1-flash-lite-preview",
    "gemini-2.5-pro",
    "gemini-2.5-flash",
    "gemini-2.5-flash-lite",
    "gemma-4-31b-it",
    "gemma-4-26b-a4b-it",
    "auto-gemini-3",
    "auto-gemini-2.5",
}


@dataclass(frozen=True)
class PromptCase:
    id: str
    category: str
    prompt: str


@dataclass
class CaseResult:
    id: str
    category: str
    status: str
    translation_status: str | None
    improve_status: str | None
    seconds: float
    source_language: str | None
    protected_spans_count: int
    missing_protected_spans: list[str]
    placeholder_leak: bool
    internal_instruction_leak: bool
    meta_prompt_output: bool
    improvement_retry_used: bool
    cyrillic_in_translation: int
    cyrillic_in_improved: int
    warnings: list[str]
    translation: str
    improved_prompt: str
    translation_seconds: float | None = None
    improve_seconds: float | None = None
    translator_provider: str = "local"
    analyzer_provider: str = "local"
    translator_model: str | None = None
    analyzer_model: str | None = None
    translation_confidence: dict[str, Any] | None = None
    improve_confidence: dict[str, Any] | None = None
    overall_confidence: dict[str, Any] | None = None
    confidence: dict[str, Any] | None = None
    error: str | None = None
    benchmark_mode: str = "matrix"
    reference_translation: bool = False


def progress_event_line(**values: Any) -> str:
    payload = {
        "event": values.pop("event"),
        "stage": values.pop("stage"),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
    payload.update({key: value for key, value in values.items() if value is not None})
    return PROGRESS_PREFIX + json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def load_prompt_cases_from_file(path: Path) -> list[PromptCase]:
    cases: list[PromptCase] = []
    current_id: str | None = None
    current_category = "custom"
    current_lines: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("### "):
            _append_case(cases, current_id, current_category, current_lines)
            parts = line[4:].split(" ", 1)
            current_id = parts[0].strip()
            current_category = parts[1].strip() if len(parts) > 1 else "custom"
            current_lines = []
        else:
            current_lines.append(line)
    _append_case(cases, current_id, current_category, current_lines)
    return cases


def adversarial_prompts() -> list[PromptCase]:
    path = ROOT / "Scripts" / "rus_to_prompt_tests" / "rus_to_prompt_cases.txt"
    return load_prompt_cases_from_file(path) if path.exists() else []


def provider_for_stage_model(model: str, configured_provider: str) -> str:
    normalized = (model or "").strip().lower()
    if normalized.startswith("gpt-oss"):
        return configured_provider
    if normalized in CODEX_STAGE_MODELS or normalized.startswith(("gpt-", "codex-", "o1", "o3", "o4")):
        return "codex"
    if normalized in GEMINI_STAGE_MODELS or normalized.startswith(("gemini-", "gemma-4-", "auto-gemini")):
        return "gemini"
    if is_deepseek_stage_model(normalized):
        return "deepseek"
    return configured_provider


def classify_external_error(message: str | None) -> str | None:
    lowered = (message or "").lower()
    if any(token in lowered for token in ["429", "rate limit", "quota", "resource exhausted"]):
        return "rate_limit"
    if any(
        token in lowered for token in ["401", "403", "unauthorized", "forbidden", "invalid api key", "api key missing"]
    ):
        return "auth_error"
    if any(token in lowered for token in ["timed out", "timeout", "deadline"]):
        return "timeout"
    return "external_error" if lowered else None


def split_model_values(values: list[str] | None, fallback: str) -> list[str]:
    raw_values = values if values else [fallback]
    models = [piece.strip() for value in raw_values for piece in str(value).split(",")]
    return [model for model in models if model]


def chunked(items: list[Any], size: int) -> list[list[Any]]:
    safe_size = max(1, size)
    return [items[index : index + safe_size] for index in range(0, len(items), safe_size)]


def read_control_file(path: str | None) -> dict[str, Any]:
    if not path:
        return {}
    try:
        decoded = json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception:
        return {}
    return decoded if isinstance(decoded, dict) else {}


def control_flag(path: str | None, key: str) -> bool:
    return bool(read_control_file(path).get(key))


def _append_case(cases: list[PromptCase], case_id: str | None, category: str, lines: list[str]) -> None:
    prompt = "\n".join(lines).strip()
    if case_id and prompt:
        cases.append(PromptCase(case_id, category, prompt))


def _extract_json_object(text: str) -> dict[str, Any] | None:
    try:
        decoded = json.loads(text)
        return decoded if isinstance(decoded, dict) else None
    except json.JSONDecodeError:
        pass
    match = re.search(r"\{.*\}", text or "", re.DOTALL)
    if not match:
        return None
    try:
        decoded = json.loads(match.group(0))
    except json.JSONDecodeError:
        return None
    return decoded if isinstance(decoded, dict) else None


def _clip_text(text: str, limit: int = 12_000) -> str:
    return text if len(text) <= limit else text[:limit] + "\n...[truncated]"


def _schema_string_list(max_items: int = 6) -> dict[str, Any]:
    return {"type": "array", "items": {"type": "string"}, "maxItems": max_items}


def confidence_value(confidence: dict[str, Any] | None) -> float | None:
    return semantic_confidence_value(confidence)


def benchmark_operation_count(mode: str, case_count: int, translator_count: int, improver_count: int) -> int:
    if mode == "translation":
        return case_count * translator_count
    if mode == "staged":
        return case_count * translator_count + case_count * improver_count
    return case_count * translator_count * improver_count


def confidence_logical_check_count(mode: str, case_count: int, translator_count: int, improver_count: int) -> int:
    if mode == "translation":
        return case_count * translator_count
    if mode == "staged":
        return case_count * translator_count + 2 * case_count * improver_count
    return 3 * case_count * translator_count * improver_count


def confidence_request_estimate(
    mode: str, case_count: int, translator_count: int, improver_count: int, batch_size: int
) -> int:
    if mode == "off":
        return 0
    batches = lambda count: (count + max(1, batch_size) - 1) // max(1, batch_size)
    if mode == "translation":
        return case_count * translator_count
    if mode == "staged":
        return case_count * translator_count + 2 * case_count * batches(improver_count)
    return 3 * case_count * translator_count * batches(improver_count)

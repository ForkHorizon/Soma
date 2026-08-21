from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from typing import Any

from soma_language_optimizer_core import _clip_text, _extract_json_object


DEFAULT_DEEPSEEK_BASE_URL = "https://api.deepseek.com"
DEFAULT_DEEPSEEK_MODEL = "deepseek-v4-flash"


def run_deepseek_json(
    *,
    prompt: str,
    schema: dict[str, Any],
    model: str,
    timeout: float,
    temp_prefix: str | None = None,
) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    started = time.monotonic()
    model = (model or DEFAULT_DEEPSEEK_MODEL).strip() or DEFAULT_DEEPSEEK_MODEL
    key = deepseek_api_key()
    if not key:
        return None, _failed_meta(
            "DeepSeek API key missing. Set SOMA_DEEPSEEK_API_KEY or DEEPSEEK_API_KEY.", model, started
        )

    body = _deepseek_payload(prompt, schema, model)
    request = urllib.request.Request(
        _chat_completions_url(),
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            wrapper = json.loads(response.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as exc:
        return None, _failed_meta(_http_error_message(exc), model, started, status_code=exc.code)
    except Exception as exc:
        return None, _failed_meta(str(exc), model, started)

    content = _deepseek_content(wrapper)
    decoded = _extract_json_object(content)
    if not isinstance(decoded, dict):
        meta = _failed_meta("DeepSeek returned invalid JSON.", model, started)
        meta["raw"] = _clip_text(content or json.dumps(wrapper, ensure_ascii=False), 2000)
        return None, meta

    usage = wrapper.get("usage") if isinstance(wrapper, dict) else None
    meta = {"provider": "deepseek", "model": model, "status": "ok", "seconds": time.monotonic() - started}
    if isinstance(usage, dict):
        meta["usage"] = usage
        meta["stats"] = {"usage": usage}
    return decoded, meta


def deepseek_api_key() -> str:
    return (os.environ.get("SOMA_DEEPSEEK_API_KEY") or os.environ.get("DEEPSEEK_API_KEY") or "").strip()


def _chat_completions_url() -> str:
    base_url = (os.environ.get("SOMA_DEEPSEEK_BASE_URL") or DEFAULT_DEEPSEEK_BASE_URL).strip().rstrip("/")
    return base_url + "/chat/completions"


def _deepseek_payload(prompt: str, schema: dict[str, Any], model: str) -> dict[str, Any]:
    full_prompt = (
        prompt
        + "\n\nReturn only one valid JSON object matching this JSON Schema. Do not wrap it in markdown.\n"
        + json.dumps(schema)
    )
    payload: dict[str, Any] = {
        "model": model,
        "messages": [
            {"role": "system", "content": "You are a strict JSON-only assistant. Return one valid JSON object."},
            {"role": "user", "content": full_prompt},
        ],
        "response_format": {"type": "json_object"},
        "temperature": 0.0,
        "stream": False,
        "max_tokens": _max_tokens(),
    }
    thinking = _thinking_option()
    if thinking:
        payload["thinking"] = thinking
    return payload


def _max_tokens() -> int:
    try:
        return max(1, int(os.environ.get("SOMA_DEEPSEEK_MAX_TOKENS", "4096")))
    except ValueError:
        return 4096


def _thinking_option() -> dict[str, str] | None:
    raw = (os.environ.get("SOMA_DEEPSEEK_THINKING") or "disabled").strip().lower()
    if raw in {"", "0", "false", "no", "off", "disabled"}:
        return {"type": "disabled"}
    if raw in {"1", "true", "yes", "on", "enabled"}:
        return {"type": "enabled"}
    return {"type": raw}


def _deepseek_content(wrapper: Any) -> str:
    if not isinstance(wrapper, dict):
        return ""
    choices = wrapper.get("choices")
    if not isinstance(choices, list) or not choices:
        return ""
    first = choices[0]
    if not isinstance(first, dict):
        return ""
    message = first.get("message")
    if not isinstance(message, dict):
        return ""
    return str(message.get("content") or "")


def _http_error_message(exc: urllib.error.HTTPError) -> str:
    try:
        body = exc.read().decode("utf-8", errors="replace")
    except Exception:
        body = ""
    return f"DeepSeek HTTP {exc.code}: {_clip_text(body or exc.reason or '', 2000)}"


def _failed_meta(error: str, model: str, started: float, status_code: int | None = None) -> dict[str, Any]:
    meta = {
        "provider": "deepseek",
        "model": model,
        "status": "failed",
        "error": _clip_text(error or "", 2000),
        "seconds": time.monotonic() - started,
    }
    if status_code is not None:
        meta["status_code"] = status_code
    return meta

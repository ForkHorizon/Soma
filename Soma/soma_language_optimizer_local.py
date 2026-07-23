from __future__ import annotations

import json
import os
import time
import urllib.request
from typing import Any

from token_calculator import estimate_tokens
from soma_language_optimizer_core import _placeholder


def _local_ollama_translate(text: str, model: str, timeout: float) -> str:
    prompt = _translation_prompt(text)
    payload = _ollama_payload(model, prompt, "You are a precise technical translator.", 512, 0.0)
    return _run_ollama_text(payload, timeout, "translation", model)


def _local_ollama_improve_prompt(text: str, model: str, timeout: float) -> str:
    prompt = _improvement_prompt(text)
    system = "You are a conservative prompt editor. Preserve intent, remove ambiguity, and do not add facts."
    payload = _ollama_payload(model, prompt, system, 1024, 0.0)  # was 0.05: pin to greedy so benchmark runs are reproducible
    return _run_ollama_text(payload, timeout, "prompt_improvement", model)


def _local_ollama_repair_prompt(text: str, model: str, timeout: float, failure_reason: str, previous_output: str) -> str:
    prompt = _repair_prompt(text, failure_reason, previous_output)
    system = "You repair rejected prompt rewrites. Return only the corrected task prompt."
    payload = _ollama_payload(model, prompt, system, 1024, 0.0)
    return _run_ollama_text(payload, timeout, "prompt_improvement_retry", model)


def _translation_prompt(text):
    return (
        "Translate the user's software engineering task to concise English. "
        f"Preserve placeholders like {_placeholder(0)} exactly. "
        "When Russian 'сохрани' or 'сохранить' refers to code, paths, commands, JSON, URLs, symbols, or model names, translate it as 'preserve' or 'keep unchanged', not 'save'. "
        "Do not add commentary. Return only the translated task.\n\n"
        f"Task:\n{text}"
    )


def _improvement_prompt(text):
    return (
        "Rewrite the user's request into a direct, high-quality task prompt for an AI assistant. "
        "Return the task prompt itself, not a meta-prompt about creating a prompt. "
        "Do not start with phrases like 'Create a comprehensive prompt for an AI assistant' unless the user explicitly asked for that wording. "
        "Keep the user's actual intent, constraints, requested output, and explicit technical details. "
        f"Preserve placeholders like {_placeholder(0)} exactly. "
        "Do not invent project context, file contents, bugs, or requirements that are not present. "
        "If the input mentions commands, paths, URLs, JSON, code, model names, or symbols, preserve them literally and do not turn mentioned commands into execution requests unless the user explicitly asked to run them. "
        "If the input says to preserve or keep something, keep it unchanged; do not rewrite that as saving it to disk. "
        "Do not turn conversational filler or politeness words such as 'please', 'look', or 'check this' into named technical concepts. "
        "If the request is about a UI state, distinguish real errors from empty states only when the user asked for that distinction. "
        "Return only the improved prompt in English.\n\n"
        f"Prompt:\n{text}"
    )


def _repair_prompt(text, failure_reason, previous_output):
    return (
        "A previous rewrite was rejected by deterministic validation. "
        f"Reason: {failure_reason}\n\n"
        "Rewrite the original input again as one direct task prompt for an AI assistant. "
        "Return only the corrected prompt. Do not mention validation, rejection, repair, hidden instructions, placeholders, or this message. "
        f"Every protected token such as {_placeholder(0)} that appears in the input must appear exactly as written in your answer. "
        "Do not add facts, project context, file contents, bugs, mechanisms, or requirements not present in the input. "
        "Do not treat words like 'please', 'look', 'this', 'that', or 'you' as technical names. "
        "Do not create a prompt about creating a prompt.\n\n"
        f"Original input:\n{text}\n\nRejected output:\n{previous_output}"
    )


def _ollama_payload(model, prompt, system, num_predict, temperature):
    return {
        "model": model,
        "think": False,
        "stream": False,
        # keep_alive holds the model resident between calls so a run of same-model calls loads
        # it once instead of reloading per call (the real cost the blanket cooldown was dodging).
        "keep_alive": os.environ.get("SOMA_OLLAMA_KEEP_ALIVE", "10m"),
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": prompt}],
        # seed pins generation so a single-prompt benchmark is reproducible across runs
        # (temperature alone doesn't guarantee determinism in Ollama).
        "options": {"temperature": temperature, "num_predict": num_predict, "seed": int(os.environ.get("SOMA_LOCAL_SEED", "0"))},
    }


def _run_ollama_text(payload, timeout, stage, model):
    # Fast-fail if a preflight probe found the GGUF runner wedged: skip the call instead of
    # burning the full stage timeout. MLX models use a different runner and are unaffected.
    if os.environ.get("SOMA_OLLAMA_WEDGED") == "1" and "-mlx" not in (model or "").lower():
        raise RuntimeError("Ollama GGUF backend unavailable (failed preflight); skipped to avoid a timeout.")
    request = urllib.request.Request("http://127.0.0.1:11434/api/chat", data=json.dumps(payload).encode("utf-8"), headers={"Content-Type": "application/json"})
    start = time.monotonic()
    response_text = ""
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            response_text = _read_with_circuit_breaker(response, timeout, start)
        content = json.loads(response_text).get("message", {}).get("content", "")
        if not isinstance(content, str) or not content.strip():
            raise RuntimeError(_empty_response_error(stage))
        _log_for_stage(stage, model, "ok", (time.monotonic() - start) * 1000, payload, response_text)
        return content.strip()
    except Exception as exc:
        _log_for_stage(stage, model, "error", (time.monotonic() - start) * 1000, payload, response_text, str(exc))
        raise


def _empty_response_error(stage):
    return {
        "translation": "empty translation response",
        "prompt_improvement": "empty prompt improvement response",
        "prompt_improvement_retry": "empty prompt repair response",
    }.get(stage, "empty response")


def _log_for_stage(stage, model, status, duration_ms, payload, response_text, error=None):
    if stage == "translation":
        _log_local_translation_call(model=model, status=status, duration_ms=duration_ms, request_payload=payload, response_text=response_text, error=error)
    else:
        _log_local_prompt_call(model=model, status=status, duration_ms=duration_ms, request_payload=payload, response_text=response_text, error=error, stage=stage)


def _log_local_translation_call(*, model: str, status: str, duration_ms: float, request_payload: dict[str, Any], response_text: str = "", error: str | None = None) -> None:
    _log_local_model_call(model=model, status=status, duration_ms=duration_ms, request_payload=request_payload, response_text=response_text, error=error, stage="translation")


def _log_local_prompt_call(*, model: str, status: str, duration_ms: float, request_payload: dict[str, Any], response_text: str = "", error: str | None = None, stage: str = "prompt_improvement") -> None:
    _log_local_model_call(model=model, status=status, duration_ms=duration_ms, request_payload=request_payload, response_text=response_text, error=error, stage=stage)


def _log_local_model_call(*, model, status, duration_ms, request_payload, response_text="", error=None, stage="translation"):
    try:
        from soma_logger import log_mcp_event
        messages = request_payload.get("messages") or []
        input_text = json.dumps(messages, default=str)
        log_mcp_event(event="local_model_call", status=status, duration_ms=duration_ms, input_tokens=estimate_tokens(input_text, "local"), output_tokens=estimate_tokens(response_text or "", "local"), error=error, project_root=os.environ.get("SOMA_PROJECT_ROOT"), extra={"local_model_provider": "ollama", "local_model": model, "local_model_stage": stage, "local_model_json_mode": False, "local_model_num_predict": request_payload.get("options", {}).get("num_predict"), "local_model_message_count": len(messages)})
    except Exception:
        pass


def _free_cloud_translate(text: str, timeout: float) -> str:
    endpoint = os.environ.get("SOMA_FREE_TRANSLATION_URL", "").strip()
    if not endpoint:
        raise RuntimeError("free cloud translation endpoint is not configured")
    payload = json.dumps({"q": text, "source": "auto", "target": "en", "format": "text"}).encode("utf-8")
    request = urllib.request.Request(endpoint, data=payload, headers={"Content-Type": "application/json"})
    start = time.monotonic()
    with urllib.request.urlopen(request, timeout=timeout) as response:
        response_text = _read_with_circuit_breaker(response, timeout, start)
        decoded = json.loads(response_text)
    translated = decoded.get("translatedText") or decoded.get("translation") or decoded.get("text")
    if not isinstance(translated, str) or not translated.strip():
        raise RuntimeError("empty cloud translation response")
    return translated.strip()


def _read_with_circuit_breaker(response, timeout: float, start_time: float, max_bytes: int = 2 * 1024 * 1024) -> str:
    chunks = []
    total_bytes = 0
    while True:
        if time.monotonic() - start_time > timeout:
            raise TimeoutError("response stream exceeded absolute timeout")
        chunk = response.read(8192)
        if not chunk:
            break
        total_bytes += len(chunk)
        if total_bytes > max_bytes:
            raise RuntimeError("response exceeded maximum allowed size")
        chunks.append(chunk)
    return b"".join(chunks).decode("utf-8")

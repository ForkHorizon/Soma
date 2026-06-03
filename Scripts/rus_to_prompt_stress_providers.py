from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path
from typing import Any

from rus_to_prompt_stress_models import (
    DEFAULT_CODEX_STAGE_REASONING_EFFORT,
    ROOT,
    _clip_text,
    _extract_json_object,
    _schema_string_list,
    classify_external_error,
)

import soma_language_optimizer as optimizer  # noqa: E402


def _api() -> Any:
    return sys.modules.get("rus_to_prompt_stress") or sys.modules[__name__]


def run_codex_json(
    *,
    prompt: str,
    schema: dict[str, Any],
    model: str,
    timeout: float,
    codex_bin: str,
    temp_prefix: str,
    reasoning_effort: str = DEFAULT_CODEX_STAGE_REASONING_EFFORT,
) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix=temp_prefix) as tmp:
        schema_path, output_path = _write_schema_files(Path(tmp), schema)
        cmd = _codex_cmd(codex_bin, model, reasoning_effort, schema_path, output_path)
        completed = _run_stage_process(cmd, prompt, timeout)
        if isinstance(completed, BaseException):
            return None, _failed_meta("codex", model, str(completed), started, reasoning_effort)
        response_text = output_path.read_text(encoding="utf-8", errors="replace") if output_path.exists() else completed.stdout
        if completed.returncode != 0:
            return None, _failed_meta("codex", model, completed.stderr or completed.stdout, started, reasoning_effort)
        decoded = _extract_json_object(response_text or "")
        if not isinstance(decoded, dict):
            meta = _failed_meta("codex", model, "Codex returned invalid JSON.", started, reasoning_effort)
            meta["raw"] = _clip_text(response_text or "", 2000)
            return None, meta
        return decoded, {"provider": "codex", "model": model, "reasoning_effort": reasoning_effort, "status": "ok", "seconds": time.monotonic() - started}


def run_gemini_json(
    *,
    prompt: str,
    schema: dict[str, Any],
    model: str,
    timeout: float,
    gemini_bin: str,
    temp_prefix: str,
) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    started = time.monotonic()
    full_prompt = prompt + "\n\nReturn only one valid JSON object matching this JSON Schema. Do not wrap it in markdown.\n" + json.dumps(schema)
    cmd = [gemini_bin, "--model", model, "--prompt", "", "--output-format", "json", "--skip-trust"]
    env = _clean_env()
    env["TERM"] = env.get("TERM") if env.get("TERM") not in {None, "", "dumb"} else "xterm-256color"
    with tempfile.TemporaryDirectory(prefix=temp_prefix) as tmp:
        completed = _run_stage_process(cmd, full_prompt, timeout, env=env, cwd=tmp)
    if isinstance(completed, BaseException):
        return None, _failed_meta("gemini", model, str(completed), started)
    wrapper = _extract_json_object(completed.stdout or "")
    response_text = _gemini_response_text(wrapper, completed.stdout or "")
    if completed.returncode != 0:
        return None, _failed_meta("gemini", model, completed.stderr or completed.stdout, started)
    decoded = _extract_json_object(response_text)
    if not isinstance(decoded, dict):
        meta = _failed_meta("gemini", model, "Gemini returned invalid JSON.", started)
        meta["raw"] = _clip_text(response_text or completed.stdout or "", 2000)
        return None, meta
    return decoded, {"provider": "gemini", "model": model, "status": "ok", "seconds": time.monotonic() - started, "stats": wrapper.get("stats") if isinstance(wrapper, dict) else None}


def run_local_ollama_json(
    *,
    prompt: str,
    schema: dict[str, Any],
    model: str,
    timeout: float,
) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    started = time.monotonic()
    payload = _ollama_payload(prompt, schema, model)
    request = urllib.request.Request("http://127.0.0.1:11434/api/chat", data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            wrapper = json.loads(response.read().decode("utf-8", errors="replace"))
    except Exception as exc:
        return None, _failed_meta("local", model, str(exc), started)
    content = str((wrapper.get("message") or {}).get("content") or "")
    decoded = _extract_json_object(content)
    if not isinstance(decoded, dict):
        meta = _failed_meta("local", model, "Local Ollama confidence model returned invalid JSON.", started)
        meta["raw"] = _clip_text(content, 2000)
        return None, meta
    return decoded, {"provider": "local", "model": model, "status": "ok", "seconds": time.monotonic() - started}


def translate_with_codex(prompt: str, model: str, timeout: float, codex_bin: str, model_profile: str, reasoning_effort: str = DEFAULT_CODEX_STAGE_REASONING_EFFORT) -> dict[str, Any]:
    return _translate_with_provider("codex", prompt, model, timeout, codex_bin, model_profile, reasoning_effort)


def translate_with_gemini(prompt: str, model: str, timeout: float, gemini_bin: str, model_profile: str) -> dict[str, Any]:
    return _translate_with_provider("gemini", prompt, model, timeout, gemini_bin, model_profile, None)


def improve_with_codex(prompt: str, model: str, timeout: float, codex_bin: str, model_profile: str, reasoning_effort: str = DEFAULT_CODEX_STAGE_REASONING_EFFORT) -> dict[str, Any]:
    return _improve_with_provider("codex", prompt, model, timeout, codex_bin, model_profile, reasoning_effort)


def improve_with_gemini(prompt: str, model: str, timeout: float, gemini_bin: str, model_profile: str) -> dict[str, Any]:
    return _improve_with_provider("gemini", prompt, model, timeout, gemini_bin, model_profile, None)


def codex_translate_schema() -> dict[str, Any]:
    return _stage_schema({"translation_status": {"type": "string"}, "translation": {"type": "string"}})


def codex_improve_schema() -> dict[str, Any]:
    return _stage_schema({"improved_prompt": {"type": "string"}})


def looks_like_codex_payload_echo(text: str) -> bool:
    decoded = _extract_json_object(text)
    return isinstance(decoded, dict) and any(key in decoded for key in ["source_language_hint", "protected_spans", "prompt"])


def _translate_with_provider(provider: str, prompt: str, model: str, timeout: float, binary: str, profile: str, effort: str | None) -> dict[str, Any]:
    original = (prompt or "").strip()
    result = _translation_result(model, provider, original)
    if not original:
        result["warnings"].append("Prompt is empty.")
        return result
    if result["source_language"] == "en":
        result.update({"status": "ok", "translation_status": "original_english", "translation_engine": None, "translation": original, "translation_tokens": optimizer.estimate_tokens(original, profile)})
        return result
    protected = optimizer.protect_spans(original)
    decoded, meta = _call_json_provider(provider, _translation_prompt(protected, result["source_language"]), codex_translate_schema(), model, timeout, binary, "translate", effort)
    translated = str((decoded or {}).get("translation") or "").strip()
    warnings = list((decoded or {}).get("warnings") or []) if isinstance((decoded or {}).get("warnings"), list) else []
    failure = _translation_failure(decoded, translated, protected, original, provider)
    if failure:
        result["warnings"] = warnings + [failure]
        return result
    restored = optimizer.restore_spans(translated, protected.spans).strip()
    result.update({"status": "ok", "translation_status": "translated", "translation": restored, "warnings": warnings, "protected_spans_count": len(protected.spans), "translation_tokens": optimizer.estimate_tokens(restored, profile), f"{provider}_seconds": meta.get("seconds")})
    return result


def _improve_with_provider(provider: str, prompt: str, model: str, timeout: float, binary: str, profile: str, effort: str | None) -> dict[str, Any]:
    translation = (prompt or "").strip()
    result = {"status": "failed", "improved_prompt": "", "improver_model": model, "warnings": [], "protected_spans_count": 0, "improvement_retry_used": False, "improved_prompt_tokens": None}
    if not translation:
        result["warnings"].append("Translation is empty.")
        return result
    protected = optimizer.protect_spans(translation)
    decoded, meta = _call_json_provider(provider, _improve_prompt(protected), codex_improve_schema(), model, timeout, binary, "improve", effort)
    improved_protected = str((decoded or {}).get("improved_prompt") or "").strip()
    warnings = list((decoded or {}).get("warnings") or []) if isinstance((decoded or {}).get("warnings"), list) else []
    if not isinstance(decoded, dict) or decoded.get("status") != "ok" or not improved_protected or looks_like_codex_payload_echo(improved_protected):
        return _degraded_result(result, translation, warnings, "improvement failed validation", profile)
    improved, validation_error = optimizer._restore_valid_improved_prompt(translation, protected, improved_protected)
    if validation_error:
        return _degraded_result(result, translation, warnings + ["Codex improvement failed validation: " + validation_error], "", profile)
    result.update({"status": "ok", "improved_prompt": improved, "warnings": warnings, "protected_spans_count": len(protected.spans), "improved_prompt_tokens": optimizer.estimate_tokens(improved, profile), f"{provider}_seconds": meta.get("seconds")})
    return result


def _call_json_provider(provider: str, prompt: str, schema: dict[str, Any], model: str, timeout: float, binary: str, stage: str, effort: str | None) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    api = _api()
    if provider == "gemini":
        return api.run_gemini_json(prompt=prompt, schema=schema, model=model, timeout=timeout, gemini_bin=binary, temp_prefix=f"soma-rus-prompt-gemini-{stage}-")
    return api.run_codex_json(prompt=prompt, schema=schema, model=model, timeout=timeout, codex_bin=binary, temp_prefix=f"soma-rus-prompt-codex-{stage}-", reasoning_effort=effort or DEFAULT_CODEX_STAGE_REASONING_EFFORT)


def _translation_result(model: str, provider: str, original: str) -> dict[str, Any]:
    return {"status": "failed", "source_language": optimizer.detect_language(original), "translation_status": None, "translation_engine": f"{provider}:{model}", "translation": "", "translator_model": model, "warnings": [], "protected_spans_count": 0, "translation_tokens": None}


def _translation_prompt(protected: Any, source_language: str) -> str:
    return "You are a precise technical translator. Do not use tools. Return JSON only. Preserve placeholders exactly.\nSource language hint: " + source_language + "\nProtected prompt:\n<<<PROMPT\n" + protected.text + "\nPROMPT>>>"


def _improve_prompt(protected: Any) -> str:
    return "You are a conservative prompt editor. Do not use tools. Return JSON only. Preserve placeholders exactly. Return a direct task prompt, not a meta-prompt.\nTranslated request:\n<<<PROMPT\n" + protected.text + "\nPROMPT>>>"


def _translation_failure(decoded: dict[str, Any] | None, translated: str, protected: Any, original: str, provider: str) -> str | None:
    if not isinstance(decoded, dict) or decoded.get("status") != "ok" or not translated:
        return f"{provider.title()} translation returned failed status or empty translation."
    if looks_like_codex_payload_echo(translated):
        return f"{provider.title()} translation echoed the control payload instead of translating the prompt."
    invalid = optimizer.invalid_placeholders(translated, len(protected.spans))
    if invalid:
        return f"{provider} provider corrupted protected placeholders: " + ", ".join(invalid[:5])
    if optimizer._cyrillic_count(translated) >= max(2, optimizer._cyrillic_count(original) // 2):
        return f"{provider.title()} translation did not sufficiently normalize Cyrillic text."
    return None


def _degraded_result(result: dict[str, Any], fallback: str, warnings: list[str], extra: str, profile: str) -> dict[str, Any]:
    if extra:
        warnings.append(extra)
    result.update({"status": "degraded", "improved_prompt": fallback, "warnings": warnings, "improved_prompt_tokens": optimizer.estimate_tokens(fallback, profile)})
    return result


def _stage_schema(properties: dict[str, Any]) -> dict[str, Any]:
    props = {"status": {"type": "string"}, "warnings": _schema_string_list()}
    props.update(properties)
    return {"type": "object", "additionalProperties": False, "properties": props, "required": list(props)}


def _write_schema_files(tmp_path: Path, schema: dict[str, Any]) -> tuple[Path, Path]:
    schema_path, output_path = tmp_path / "schema.json", tmp_path / "last-message.json"
    schema_path.write_text(json.dumps(schema, indent=2), encoding="utf-8")
    return schema_path, output_path


def _codex_cmd(codex_bin: str, model: str, effort: str, schema_path: Path, output_path: Path) -> list[str]:
    return [codex_bin, "exec", "--model", model, "-c", f'model_reasoning_effort="{effort}"', "--sandbox", "read-only", "--cd", str(ROOT), "--ephemeral", "--ignore-rules", "--color", "never", "--output-schema", str(schema_path), "--output-last-message", str(output_path), "-"]


def _run_stage_process(cmd: list[str], prompt: str, timeout: float, env: dict[str, str] | None = None, cwd: str | None = None) -> subprocess.CompletedProcess[str] | BaseException:
    try:
        return subprocess.run(cmd, input=prompt, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, env=env or _clean_env(), cwd=cwd, check=False)
    except (subprocess.TimeoutExpired, OSError) as exc:
        return exc


def _clean_env() -> dict[str, str]:
    env = os.environ.copy()
    env.pop("SOMA_PROJECT_ROOT", None)
    return env


def _failed_meta(provider: str, model: str, error: str, started: float, effort: str | None = None) -> dict[str, Any]:
    meta = {"provider": provider, "model": model, "status": "failed", "error": _clip_text(error or "", 2000), "error_type": classify_external_error(error), "seconds": time.monotonic() - started}
    if effort is not None:
        meta["reasoning_effort"] = effort
    return meta


def _gemini_response_text(wrapper: dict[str, Any] | None, stdout: str) -> str:
    if isinstance(wrapper, dict) and isinstance(wrapper.get("response"), str):
        return str(wrapper.get("response") or "")
    if isinstance(wrapper, dict) and "status" in wrapper:
        return json.dumps(wrapper, ensure_ascii=False)
    return stdout


def _ollama_payload(prompt: str, schema: dict[str, Any], model: str) -> dict[str, Any]:
    full_prompt = prompt + "\n\nReturn only one valid JSON object matching this JSON Schema.\n" + json.dumps(schema)
    return {"model": model, "think": False, "stream": False, "messages": [{"role": "system", "content": "You are a strict JSON-only quality referee."}, {"role": "user", "content": full_prompt}], "format": schema, "options": {"temperature": 0.0, "num_predict": int(os.environ.get("SOMA_LOCAL_CONFIDENCE_NUM_PREDICT", "4096"))}}

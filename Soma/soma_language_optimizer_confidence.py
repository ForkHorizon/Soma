from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

from soma_deepseek_api import run_deepseek_json
from soma_language_optimizer_core import _clip_text, _cyrillic_count, _extract_json_object, _improved_prompt_sanity_error, _string_list, is_deepseek_stage_model, protect_spans


def _confidence_schema() -> dict[str, Any]:
    score_schema = {"type": "integer", "minimum": 1, "maximum": 5}
    return {"$schema": "https://json-schema.org/draft/2020-12/schema", "type": "object", "additionalProperties": False, "properties": {"status": {"type": "string", "enum": ["ok", "review", "failed"]}, "confidence": {"type": "number", "minimum": 0, "maximum": 1}, "verdict": {"type": "string", "enum": ["pass", "review", "fail"]}, "scores": {"type": "object", "additionalProperties": False, "properties": {"intent_preservation": score_schema, "english_quality": score_schema, "protected_span_preservation": score_schema, "actionability": score_schema, "concision": score_schema, "no_invention": score_schema}, "required": ["intent_preservation", "english_quality", "protected_span_preservation", "actionability", "concision", "no_invention"]}, "warnings": {"type": "array", "items": {"type": "string"}, "maxItems": 6}, "notes": {"type": "array", "items": {"type": "string"}, "maxItems": 6}}, "required": ["status", "confidence", "verdict", "scores", "warnings", "notes"]}


def _confidence_prompt(*, source_prompt: str, translation: str, improved_prompt: str, pipeline_status: str, pipeline_warnings: list[str]) -> str:
    protected_spans = list(dict.fromkeys(protect_spans(source_prompt).spans))
    payload = {"source_prompt": source_prompt, "translation": translation, "improved_prompt": improved_prompt, "pipeline_status": pipeline_status, "pipeline_warnings": pipeline_warnings, "protected_spans": protected_spans, "local_checks": {"cyrillic_in_translation": _cyrillic_count(translation), "cyrillic_in_improved": _cyrillic_count(improved_prompt), "improved_sanity_error": _improved_prompt_sanity_error(translation or source_prompt, improved_prompt)}}
    return ("You are a strict prompt-quality referee. Do not use tools. Do not inspect the repository. Judge only the JSON payload below.\n\nReturn JSON only with this schema: {\"status\":\"ok|review|failed\",\"confidence\":0.0,\"verdict\":\"pass|review|fail\",\"scores\":{\"intent_preservation\":1,\"english_quality\":1,\"protected_span_preservation\":1,\"actionability\":1,\"concision\":1,\"no_invention\":1},\"warnings\":[\"...\"],\"notes\":[\"...\"]}.\n\nScoring rules:\n- confidence is 0..1 for whether the improved_prompt is safe to copy as the final English task prompt.\n- Penalize invented requirements, meta-prompts about writing prompts, internal instruction leakage, lost code/paths/URLs/JSON/commands, or treating politeness words as technical concepts.\n- If protected_spans is empty, set protected_span_preservation to 5 unless the output leaked internal placeholders.\n- A degraded pipeline can still receive moderate confidence if the translation is a usable fallback, but mark review unless it is clearly polished.\n- Use 'failed' only when the final prompt is unsafe, empty, misleading, or unusable.\n\n" f"Payload:\n{_clip_text(json.dumps(payload, ensure_ascii=False, indent=2))}")


def score_general_prompt_confidence(*, source_prompt: str, translation: str, improved_prompt: str, pipeline_status: str = "ok", pipeline_warnings: list[str] | None = None, confidence_model: str = "gpt-5.4-mini", reasoning_effort: str = "medium", timeout: float | None = None, codex_bin: str | None = None) -> dict[str, Any]:
    model = confidence_model or "gpt-5.4-mini"
    timeout = timeout or float(os.environ.get("SOMA_RUS_TO_PROMPT_CONFIDENCE_TIMEOUT", "180"))
    codex_bin = codex_bin or os.environ.get("SOMA_CODEX_BIN", "codex")
    started = time.monotonic()
    provider = "deepseek" if is_deepseek_stage_model(model) else "codex"
    result = _base_confidence_result(model, reasoning_effort, provider=provider)
    prompt = _confidence_prompt(source_prompt=source_prompt, translation=translation, improved_prompt=improved_prompt, pipeline_status=pipeline_status, pipeline_warnings=pipeline_warnings or [])
    if provider == "deepseek":
        return _score_confidence_deepseek(result, prompt, model, timeout, started)
    with tempfile.TemporaryDirectory(prefix="soma-rus-prompt-confidence-") as tmp:
        paths = _confidence_paths(tmp)
        completed = _run_confidence_codex(codex_bin, model, reasoning_effort, paths, prompt, timeout, started, result)
        if completed is None:
            return result
        return _finish_confidence_result(result, completed, paths["output"], started)


def _base_confidence_result(model, reasoning_effort, provider="codex"):
    return {"provider": provider, "model": model, "reasoning_effort": reasoning_effort, "status": "failed", "confidence": None, "verdict": None, "scores": {}, "warnings": [], "notes": [], "seconds": 0}


def _score_confidence_deepseek(result, prompt, model, timeout, started):
    decoded, meta = run_deepseek_json(prompt=prompt, schema=_confidence_schema(), model=model, timeout=timeout, temp_prefix="soma-rus-prompt-deepseek-confidence-")
    if not isinstance(decoded, dict) or meta.get("status") != "ok":
        result.update({"error": str(meta.get("error") or "DeepSeek confidence check failed."), "seconds": time.monotonic() - started})
        if meta.get("stats") is not None:
            result["stats"] = meta.get("stats")
        return result
    result.update(_decoded_confidence_fields(decoded, started))
    if meta.get("stats") is not None:
        result["stats"] = meta.get("stats")
    return result


def _confidence_paths(tmp):
    tmp_path = Path(tmp)
    schema_path = tmp_path / "schema.json"
    output_path = tmp_path / "last-message.json"
    schema_path.write_text(json.dumps(_confidence_schema(), indent=2), encoding="utf-8")
    return {"schema": schema_path, "output": output_path}


def _confidence_command(codex_bin, model, reasoning_effort, paths):
    root = Path(__file__).resolve().parents[1]
    return [codex_bin, "exec", "--model", model, "-c", f'model_reasoning_effort="{reasoning_effort}"', "--sandbox", "read-only", "--cd", str(root), "--ephemeral", "--ignore-rules", "--color", "never", "--output-schema", str(paths["schema"]), "--output-last-message", str(paths["output"]), "-"]


def _run_confidence_codex(codex_bin, model, reasoning_effort, paths, prompt, timeout, started, result):
    environment = os.environ.copy()
    environment.pop("SOMA_PROJECT_ROOT", None)
    try:
        return subprocess.run(_confidence_command(codex_bin, model, reasoning_effort, paths), input=prompt, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, env=environment, check=False)
    except (subprocess.TimeoutExpired, OSError) as exc:
        result.update({"error": str(exc), "seconds": time.monotonic() - started})
        return None


def _finish_confidence_result(result, completed, output_path, started):
    response_text = output_path.read_text(encoding="utf-8", errors="replace") if output_path.exists() else completed.stdout
    if completed.returncode != 0:
        result.update({"error": _clip_text((completed.stderr or completed.stdout or "").strip(), 2000), "seconds": time.monotonic() - started})
        return result
    decoded = _extract_json_object(response_text or "")
    if not isinstance(decoded, dict):
        result.update({"error": "Codex returned invalid confidence JSON.", "raw": _clip_text(response_text or "", 2000), "seconds": time.monotonic() - started})
        return result
    result.update(_decoded_confidence_fields(decoded, started))
    return result


def _decoded_confidence_fields(decoded, started):
    confidence = decoded.get("confidence")
    confidence = max(0.0, min(1.0, float(confidence))) if isinstance(confidence, (int, float)) else None
    return {"status": str(decoded.get("status") or "review"), "confidence": confidence, "verdict": str(decoded.get("verdict") or "review"), "scores": decoded.get("scores") if isinstance(decoded.get("scores"), dict) else {}, "warnings": _string_list(decoded.get("warnings")), "notes": _string_list(decoded.get("notes")), "seconds": time.monotonic() - started}

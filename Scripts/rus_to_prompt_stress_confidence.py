from __future__ import annotations

import json
import os
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

from rus_to_prompt_stress_models import (
    DEFAULT_CONFIDENCE_REASONING_EFFORT,
    DEFAULT_HYBRID_DISAGREEMENT_THRESHOLD,
    DEFAULT_HYBRID_LOCAL_CONFIDENCE_THRESHOLD,
    DEFAULT_LOCAL_CONFIDENCE_MODELS,
    ROOT,
    CaseResult,
    PromptCase,
    _clip_text,
    _extract_json_object,
    _schema_string_list,
    chunked,
    classify_external_error,
    confidence_value,
)
from rus_to_prompt_stress_results import apply_deterministic_confidence_caps, failed_confidence_result


ConfidenceItem = tuple[str, PromptCase, CaseResult]


def _api() -> Any:
    return sys.modules.get("rus_to_prompt_stress") or sys.modules[__name__]


def codex_confidence_schema() -> dict[str, Any]:
    return _confidence_item_schema()


def confidence_batch_schema() -> dict[str, Any]:
    return {"type": "object", "properties": {"results": {"type": "array", "items": _confidence_item_schema()}}, "required": ["results"]}


def confidence_payload(case: PromptCase, result: CaseResult, stage: str, item_id: str | None = None) -> dict[str, Any]:
    return {"id": item_id, "case_id": case.id, "category": case.category, "source_prompt": case.prompt, "stage": stage, "translation": result.translation, "improved_prompt": result.improved_prompt, "status": result.status, "warnings": result.warnings, "protected_span_failures": result.missing_protected_spans, "translator_model": result.translator_model, "analyzer_model": result.analyzer_model}


def confidence_stage_rules(stage: str) -> tuple[str, str]:
    if stage == "translation":
        return "- confidence is 0..1 for translation fidelity.\n", "- Judge source_prompt -> translation only.\n"
    if stage == "improve":
        return "- confidence is 0..1 for prompt polish.\n", "- Judge translation -> improved_prompt only.\n"
    return "- confidence is 0..1 for final prompt safety.\n", "- Judge source_prompt -> translation -> improved_prompt.\n"


def build_codex_confidence_prompt(case: PromptCase, result: CaseResult, stage: str = "overall") -> str:
    payload = confidence_payload(case, result, stage)
    rule, stage_rule = confidence_stage_rules(stage)
    return "You are a strict prompt-quality referee. Do not use tools. Judge only the JSON payload below.\n" + rule + stage_rule + "Payload:\n" + json.dumps(payload, ensure_ascii=False)


def confidence_item_id(result: CaseResult, stage: str) -> str:
    return "|".join([result.id, result.translator_model or "", result.analyzer_model or "", stage])


def confidence_chunks_for_group(case: PromptCase, results: list[CaseResult], stage: str, batch_size: int) -> list[list[ConfidenceItem]]:
    if not results:
        return []
    if {result.id for result in results} != {case.id}:
        raise ValueError("confidence batch cannot mix different cases")
    if len({result.translator_model for result in results}) != 1:
        raise ValueError("confidence batch cannot mix different translator models")
    return chunked([(confidence_item_id(result, stage), case, result) for result in results], batch_size)


def score_confidence_with_codex(case: PromptCase, result: CaseResult, model: str, timeout: float, codex_bin: str = "codex", stage: str = "overall", reasoning_effort: str = DEFAULT_CONFIDENCE_REASONING_EFFORT) -> dict[str, Any]:
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="soma-rus-prompt-confidence-") as tmp:
        schema_path, output_path = Path(tmp) / "schema.json", Path(tmp) / "last-message.json"
        schema_path.write_text(json.dumps(codex_confidence_schema()), encoding="utf-8")
        cmd = [codex_bin, "exec", "--model", model, "-c", f'model_reasoning_effort="{reasoning_effort}"', "--sandbox", "read-only", "--cd", str(ROOT), "--ephemeral", "--ignore-rules", "--color", "never", "--output-schema", str(schema_path), "--output-last-message", str(output_path), "-"]
        completed = _run_codex(cmd, build_codex_confidence_prompt(case, result, stage), timeout)
        if isinstance(completed, BaseException):
            return _confidence_error("codex", model, stage, str(completed), started, reasoning_effort)
        if completed.returncode != 0:
            return _confidence_error("codex", model, stage, completed.stderr or completed.stdout, started, reasoning_effort)
        decoded = _extract_json_object(output_path.read_text(encoding="utf-8", errors="replace") if output_path.exists() else completed.stdout)
    if not isinstance(decoded, dict):
        return _confidence_error("codex", model, stage, "Codex returned invalid confidence JSON.", started, reasoning_effort)
    return normalize_confidence_payload(decoded, provider="codex", model=model, stage=stage, seconds=time.monotonic() - started, reasoning_effort=reasoning_effort)


def score_confidence_with_gemini(case: PromptCase, result: CaseResult, model: str, timeout: float, gemini_bin: str = "/opt/homebrew/bin/gemini", stage: str = "overall") -> dict[str, Any]:
    started = time.monotonic()
    decoded, meta = _api().run_gemini_json(prompt=build_codex_confidence_prompt(case, result, stage), schema=codex_confidence_schema(), model=model, timeout=timeout, gemini_bin=gemini_bin, temp_prefix="soma-rus-prompt-gemini-confidence-")
    if decoded is None or meta.get("status") != "ok":
        return _confidence_error("gemini", model, stage, str(meta.get("error") or "Gemini confidence check failed."), started, stats=meta.get("stats"))
    return normalize_confidence_payload(decoded, provider="gemini", model=model, stage=stage, seconds=float(meta.get("seconds") or 0), stats=meta.get("stats"))


def score_confidence_with_local(case: PromptCase, result: CaseResult, model: str, timeout: float, stage: str = "overall") -> dict[str, Any]:
    decoded, meta = _api().run_local_ollama_json(prompt=build_codex_confidence_prompt(case, result, stage), schema=codex_confidence_schema(), model=model, timeout=timeout)
    if decoded is None or meta.get("status") != "ok":
        return _confidence_error("local", model, stage, str(meta.get("error") or "Local confidence check failed."), time.monotonic())
    return normalize_confidence_payload(decoded, provider="local", model=model, stage=stage, seconds=float(meta.get("seconds") or 0))


def score_confidence_batch_with_provider(items: list[ConfidenceItem], **kwargs: Any) -> dict[str, dict[str, Any]]:
    provider = kwargs["provider"]
    if not items:
        return {}
    if provider == "hybrid":
        return score_hybrid_confidence_batch(items, **kwargs)
    if len(items) == 1:
        return _single_confidence(items[0], **kwargs)
    parsed = _batch_confidence(items, **kwargs)
    if parsed is not None:
        return parsed
    midpoint = max(1, len(items) // 2)
    left = score_confidence_batch_with_provider(items[:midpoint], **kwargs)
    right = score_confidence_batch_with_provider(items[midpoint:], **kwargs)
    left.update(right)
    return left


def score_hybrid_confidence_batch(items: list[ConfidenceItem], **kwargs: Any) -> dict[str, dict[str, Any]]:
    local_models = list(dict.fromkeys(kwargs.get("local_models") or DEFAULT_LOCAL_CONFIDENCE_MODELS))[:2]
    local_results = [_local_batch(items, model, kwargs) for model in local_models]
    final, fallback_items, local_by_item, reasons = {}, [], {}, {}
    aggregate_model = " + ".join(local_models)
    for item_id, case, result in items:
        confidences = [batch.get(item_id) or failed_confidence_result(model, kwargs["stage"], "Local confidence judge did not return this item.", provider="local") for model, batch in zip(local_models, local_results)]
        local_by_item[item_id] = confidences
        reason = hybrid_escalation_reason(confidences, threshold=kwargs.get("hybrid_local_threshold", DEFAULT_HYBRID_LOCAL_CONFIDENCE_THRESHOLD), disagreement_threshold=kwargs.get("hybrid_disagreement_threshold", DEFAULT_HYBRID_DISAGREEMENT_THRESHOLD))
        if reason:
            fallback_items.append((item_id, case, result))
            reasons[item_id] = reason
        else:
            final[item_id] = aggregate_local_confidences(confidences, model=aggregate_model, stage=kwargs["stage"], batch_item_id=item_id)
    final.update(_fallback_confidences(fallback_items, local_by_item, reasons, aggregate_model, kwargs))
    return final


def normalize_confidence_payload(decoded: dict[str, Any], *, provider: str, model: str, stage: str, seconds: float, reasoning_effort: str | None = None, batch_size: int | None = None, batch_seconds: float | None = None, stats: Any | None = None) -> dict[str, Any]:
    confidence = _normalized_confidence(decoded.get("confidence"))
    payload = {"provider": provider, "model": model, "stage": stage, "status": str(decoded.get("status") or "review"), "confidence": confidence, "verdict": str(decoded.get("verdict") or "review"), "scores": decoded.get("scores") if isinstance(decoded.get("scores"), dict) else {}, "warnings": list(decoded.get("warnings") or [])[:6] if isinstance(decoded.get("warnings"), list) else [], "notes": list(decoded.get("notes") or [])[:6] if isinstance(decoded.get("notes"), list) else [], "seconds": seconds}
    payload.update({k: v for k, v in {"reasoning_effort": reasoning_effort, "batch_size": batch_size, "batch_seconds": batch_seconds, "stats": stats}.items() if v is not None})
    return payload


def parse_batch_confidence_response(decoded: dict[str, Any] | None, meta: dict[str, Any], *, provider: str, model: str, stage: str, item_ids: set[str], reasoning_effort: str | None = None) -> dict[str, dict[str, Any]] | None:
    if decoded is None or meta.get("status") != "ok" or not isinstance(decoded.get("results"), list):
        return None
    batch_seconds = float(meta.get("seconds") or 0.0)
    by_id = {}
    for item in decoded["results"]:
        item_id = str(item.get("id") or "") if isinstance(item, dict) else ""
        if item_id in item_ids and item_id not in by_id:
            by_id[item_id] = normalize_confidence_payload(item, provider=provider, model=model, stage=stage, seconds=batch_seconds / max(len(item_ids), 1), reasoning_effort=reasoning_effort, batch_size=len(item_ids), batch_seconds=batch_seconds, stats=meta.get("stats"))
            by_id[item_id]["batch_item_id"] = item_id
    return by_id if set(by_id) == item_ids else None


def hybrid_escalation_reason(local_confidences: list[dict[str, Any]], *, threshold: float = DEFAULT_HYBRID_LOCAL_CONFIDENCE_THRESHOLD, disagreement_threshold: float = DEFAULT_HYBRID_DISAGREEMENT_THRESHOLD) -> str | None:
    values = [confidence_value(confidence) for confidence in local_confidences]
    if len(values) < 2 or any(value is None for value in values):
        return "Need two local confidence judges."
    if any(confidence.get("status") == "failed" or confidence.get("verdict") == "fail" for confidence in local_confidences):
        return "A local confidence judge failed."
    if min(values) < threshold:
        return f"Local confidence below threshold {threshold:.2f}."
    if max(values) - min(values) >= disagreement_threshold:
        return f"Local judges disagreed by {max(values) - min(values):.2f}."
    return None


def aggregate_local_confidences(local_confidences: list[dict[str, Any]], *, model: str, stage: str, batch_item_id: str, threshold: float = DEFAULT_HYBRID_LOCAL_CONFIDENCE_THRESHOLD) -> dict[str, Any]:
    numeric = [value for value in [confidence_value(confidence) for confidence in local_confidences] if value is not None]
    average = statistics.mean(numeric) if numeric else None
    status = "failed" if average is None else ("review" if average < threshold or any(confidence.get("status") == "review" for confidence in local_confidences) else "ok")
    warnings = [f"{c.get('model') or 'local'}: {w}" for c in local_confidences for w in (c.get("warnings") or [])]
    return {"provider": "hybrid", "model": model, "stage": stage, "status": status, "confidence": average, "verdict": "pass" if status == "ok" else "review", "scores": _average_scores(local_confidences), "warnings": warnings[:6], "notes": [], "seconds": sum(float(c.get("seconds") or 0) for c in local_confidences), "batch_item_id": batch_item_id, "local_judges": local_confidences, "hybrid_escalated": False}


def _single_confidence(item: ConfidenceItem, **kwargs: Any) -> dict[str, dict[str, Any]]:
    item_id, case, result = item
    provider, model, stage = kwargs["provider"], kwargs["model"], kwargs["stage"]
    if provider == "gemini":
        confidence = score_confidence_with_gemini(case, result, model, kwargs["timeout"], kwargs["gemini_bin"], stage)
    elif provider == "local":
        confidence = score_confidence_with_local(case, result, model, kwargs["timeout"], stage)
    else:
        confidence = score_confidence_with_codex(case, result, model, kwargs["timeout"], kwargs["codex_bin"], stage, kwargs["reasoning_effort"])
    confidence["batch_item_id"] = item_id
    return {item_id: apply_deterministic_confidence_caps(confidence, result, stage)}


def _batch_confidence(items: list[ConfidenceItem], **kwargs: Any) -> dict[str, dict[str, Any]] | None:
    prompt = build_batch_confidence_prompt(items, kwargs["stage"])
    provider, model = kwargs["provider"], kwargs["model"]
    if provider == "gemini":
        decoded, meta = _api().run_gemini_json(prompt=prompt, schema=confidence_batch_schema(), model=model, timeout=kwargs["timeout"], gemini_bin=kwargs["gemini_bin"], temp_prefix="soma-rus-prompt-gemini-confidence-batch-")
    elif provider == "local":
        decoded, meta = _api().run_local_ollama_json(prompt=prompt, schema=confidence_batch_schema(), model=model, timeout=kwargs["timeout"])
    else:
        decoded, meta = _api().run_codex_json(prompt=prompt, schema=confidence_batch_schema(), model=model, timeout=kwargs["timeout"], codex_bin=kwargs["codex_bin"], temp_prefix="soma-rus-prompt-codex-confidence-batch-", reasoning_effort=kwargs["reasoning_effort"])
    return parse_batch_confidence_response(decoded, meta, provider=provider, model=model, stage=kwargs["stage"], item_ids={item[0] for item in items}, reasoning_effort=kwargs.get("reasoning_effort"))


def build_batch_confidence_prompt(items: list[ConfidenceItem], stage: str) -> str:
    payload = {"confidence_stage": stage, "items": [confidence_payload(case, result, stage, item_id) for item_id, case, result in items]}
    return "You are a strict prompt-quality referee. Do not use tools. Judge each JSON payload item independently.\nPayload:" + json.dumps(payload, ensure_ascii=False)


def _local_batch(items: list[ConfidenceItem], model: str, kwargs: dict[str, Any]) -> dict[str, dict[str, Any]]:
    local_kwargs = dict(kwargs)
    local_kwargs.update({"provider": "local", "model": model})
    return score_confidence_batch_with_provider(items, **local_kwargs)


def _fallback_confidences(items: list[ConfidenceItem], local_by_item: dict[str, list[dict[str, Any]]], reasons: dict[str, str], aggregate_model: str, kwargs: dict[str, Any]) -> dict[str, dict[str, Any]]:
    provider = kwargs.get("hybrid_fallback_provider", "gemini")
    if not items:
        return {}
    if provider == "off":
        return {item_id: aggregate_local_confidences(local_by_item[item_id], model=aggregate_model, stage=kwargs["stage"], batch_item_id=item_id) for item_id, _case, _result in items}
    fallback = _fallback_batch(items, provider, kwargs)
    return {item_id: _attach_or_keep_local(item_id, fallback.get(item_id), local_by_item[item_id], reasons[item_id], aggregate_model, kwargs["stage"]) for item_id, _case, _result in items}


def _fallback_batch(items: list[ConfidenceItem], provider: str, kwargs: dict[str, Any]) -> dict[str, dict[str, Any]]:
    fallback_kwargs = dict(kwargs)
    fallback_kwargs.update({"provider": provider, "model": kwargs.get("hybrid_gemini_model") or kwargs["model"]})
    return score_confidence_batch_with_provider(items, **fallback_kwargs)


def _attach_or_keep_local(item_id: str, fallback: dict[str, Any] | None, local: list[dict[str, Any]], reason: str, aggregate_model: str, stage: str) -> dict[str, Any]:
    if fallback and not fallback.get("error"):
        fallback = dict(fallback)
        fallback.update({"provider": "hybrid", "fallback_provider": fallback.get("provider"), "fallback_model": fallback.get("model"), "local_judges": local, "hybrid_escalated": True, "hybrid_escalation_reason": reason})
        return fallback
    confidence = aggregate_local_confidences(local, model=aggregate_model + " local fallback", stage=stage, batch_item_id=item_id)
    numeric = [value for value in [confidence_value(item) for item in local] if value is not None]
    if numeric:
        confidence["confidence"] = min(numeric)
    warnings = list(confidence.get("warnings") or [])
    warnings.insert(0, "Online fallback failed; using conservative local confidence fallback. " + str((fallback or {}).get("error") or "online fallback returned no usable result"))
    confidence.update({"status": "review", "fallback_failed": True, "fallback_error_type": (fallback or {}).get("error_type"), "warnings": warnings[:6], "hybrid_escalated": True, "hybrid_escalation_reason": reason})
    return confidence


def _average_scores(confidences: list[dict[str, Any]]) -> dict[str, int]:
    keys = ["intent_preservation", "english_quality", "protected_span_preservation", "actionability", "concision", "no_invention"]
    return {key: int(round(statistics.mean(values))) for key in keys if (values := [int(c.get("scores", {}).get(key)) for c in confidences if isinstance(c.get("scores"), dict) and isinstance(c.get("scores", {}).get(key), (int, float))])}


def _normalized_confidence(value: Any) -> float | None:
    if not isinstance(value, (int, float)):
        return None
    return min(1.0, max(0.0, float(value)))


def _confidence_item_schema() -> dict[str, Any]:
    return {"type": "object", "additionalProperties": True, "properties": {"status": {"type": "string"}, "confidence": {"type": ["number", "null"]}, "verdict": {"type": "string"}, "scores": {"type": "object"}, "warnings": _schema_string_list(), "notes": _schema_string_list()}}


def _run_codex(cmd: list[str], prompt: str, timeout: float) -> subprocess.CompletedProcess[str] | BaseException:
    env = os.environ.copy()
    env.pop("SOMA_PROJECT_ROOT", None)
    try:
        return subprocess.run(cmd, input=prompt, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, env=env, check=False)
    except (subprocess.TimeoutExpired, OSError) as exc:
        return exc


def _confidence_error(provider: str, model: str, stage: str, error: str, started: float, reasoning_effort: str | None = None, stats: Any | None = None) -> dict[str, Any]:
    payload = {"provider": provider, "model": model, "stage": stage, "status": "failed", "confidence": None, "error": _clip_text(error, 2000), "error_type": classify_external_error(error), "seconds": time.monotonic() - started}
    payload.update({key: value for key, value in {"reasoning_effort": reasoning_effort, "stats": stats}.items() if value is not None})
    return payload

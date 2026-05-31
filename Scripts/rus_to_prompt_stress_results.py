from __future__ import annotations

import statistics
from dataclasses import asdict
from typing import Any

from rus_to_prompt_stress_models import CaseResult, PromptCase, confidence_value

import soma_language_optimizer as optimizer  # noqa: E402


def missing_spans(prompt: str, *outputs: str) -> list[str]:
    protected = optimizer.protect_spans(prompt)
    combined = "\n".join(outputs)
    return [span for span in protected.spans if span and span not in combined]


def has_internal_placeholder_leak(text: str, source: str) -> bool:
    return "__SOMA_PROTECTED_SPAN_" in (text or "") and "__SOMA_PROTECTED_SPAN_" not in (source or "")


def has_internal_instruction_leak(text: str, source: str = "") -> bool:
    lowered = (text or "").lower()
    return any(marker in lowered for marker in ["return only the improved prompt", "rewrite the user's request", "hidden system prompt"])


def is_meta_prompt(text: str) -> bool:
    lowered = (text or "").strip().lower()
    return lowered.startswith(("create a prompt", "create a task prompt", "generate a prompt"))


def failed_confidence_result(model: str, stage: str, error: str, reasoning_effort: str | None = None, provider: str = "codex") -> dict[str, Any]:
    payload = {"provider": provider, "model": model, "stage": stage, "status": "failed", "confidence": None, "verdict": "fail", "warnings": [error], "error": error}
    if reasoning_effort:
        payload["reasoning_effort"] = reasoning_effort
    return payload


def translation_confidence_allows_improve(confidence: dict[str, Any] | None, threshold: float) -> bool:
    value = confidence_value(confidence)
    return bool(confidence and confidence.get("status") != "failed" and value is not None and value >= threshold)


def translation_rejection_reason(confidence: dict[str, Any] | None, threshold: float) -> str:
    value = confidence_value(confidence)
    if confidence is None or confidence.get("status") == "failed":
        return "Translation confidence check failed; skipped improver stage."
    return f"Translation confidence {value or 0:.2f} is below threshold {threshold:.2f}; skipped improver stage."


def build_translation_rejected_result(
    case: PromptCase,
    translator_model: str | None,
    analyzer_model: str | None,
    translator_provider: str,
    analyzer_provider: str,
    translation_payload: dict[str, Any],
    translation_seconds: float,
    reason: str,
) -> CaseResult:
    translation = str(translation_payload.get("translation") or "")
    return _case_result(case, translator_model, analyzer_model, translator_provider, analyzer_provider, translation_payload, None, translation_seconds, 0.0, "translation_rejected", reason)


def build_translation_only_result(
    case: PromptCase,
    translator_model: str | None,
    analyzer_model: str | None,
    translator_provider: str,
    analyzer_provider: str,
    translation_payload: dict[str, Any],
    translation_seconds: float,
) -> CaseResult:
    return _case_result(case, translator_model, analyzer_model, translator_provider, analyzer_provider, translation_payload, None, translation_seconds, 0.0, "translation_only", None)


def build_case_result_from_payloads(
    case: PromptCase,
    translator_model: str | None,
    analyzer_model: str | None,
    translator_provider: str,
    analyzer_provider: str,
    translation_payload: dict[str, Any],
    improve_payload: dict[str, Any] | None,
    translation_seconds: float,
    improve_seconds: float,
) -> CaseResult:
    improve_status = str((improve_payload or {}).get("status") or "failed")
    status = "ok" if improve_status == "ok" else improve_status
    if translation_payload.get("status") != "ok":
        status = "translation_failed"
    return _case_result(case, translator_model, analyzer_model, translator_provider, analyzer_provider, translation_payload, improve_payload, translation_seconds, improve_seconds, status, None)


def apply_deterministic_confidence_caps(confidence: dict[str, Any], result: CaseResult, stage: str) -> dict[str, Any]:
    capped = dict(confidence)
    caps = deterministic_confidence_caps(result, stage)
    if not caps:
        return capped
    cap_value = min(value for value, _reason in caps)
    reasons = [reason for _value, reason in caps]
    current = confidence_value(capped)
    if current is None or current > cap_value:
        capped["confidence"] = cap_value
    capped["status"] = "review"
    capped["verdict"] = "fail" if cap_value <= 0.5 else "review"
    capped["deterministic_confidence_cap_reasons"] = reasons
    return capped


def deterministic_confidence_caps(result: CaseResult, stage: str) -> list[tuple[float, str]]:
    caps: list[tuple[float, str]] = []
    if result.placeholder_leak:
        caps.append((0.50, "internal placeholder leak"))
    if result.internal_instruction_leak:
        caps.append((0.50, "internal instruction leak"))
    if stage == "translation" and result.cyrillic_in_translation > 0:
        caps.append((0.65, "translation still contains Cyrillic"))
    if result.missing_protected_spans:
        caps.append((0.60, "missing protected spans"))
    return caps


def apply_run_health(summary: dict[str, Any], total_operations: int) -> dict[str, Any]:
    issue_counts = _issue_counts(summary, total_operations)
    summary["issue_counts"] = issue_counts
    if issue_counts.get("incomplete_operations"):
        summary["run_status"] = "failed"
        summary["success"] = False
    elif any(issue_counts.values()):
        summary["run_status"] = "completed_with_issues"
        summary["success"] = False
    else:
        summary["run_status"] = "ok"
        summary["success"] = True
    return summary


def summarize(results: list[CaseResult], started_at: str, finished_at: str) -> dict[str, Any]:
    rows = [asdict(result) for result in results]
    confidence_values = [value for result in results for value in _confidence_values(result)]
    summary = {"started_at": started_at, "finished_at": finished_at, "total": len(results), "results": rows}
    summary.update(_result_counts(results))
    summary["avg_confidence"] = statistics.mean(confidence_values) if confidence_values else None
    return summary


def _case_result(
    case: PromptCase,
    translator_model: str | None,
    analyzer_model: str | None,
    translator_provider: str,
    analyzer_provider: str,
    translation_payload: dict[str, Any],
    improve_payload: dict[str, Any] | None,
    translation_seconds: float,
    improve_seconds: float,
    status: str,
    error: str | None,
) -> CaseResult:
    translation = str(translation_payload.get("translation") or "")
    improved = str((improve_payload or {}).get("improved_prompt") or "")
    warnings = list(translation_payload.get("warnings") or []) + list((improve_payload or {}).get("warnings") or [])
    return CaseResult(case.id, case.category, status, translation_payload.get("translation_status"), (improve_payload or {}).get("status"), translation_seconds + improve_seconds, translation_payload.get("source_language"), int(translation_payload.get("protected_spans_count") or 0) + int((improve_payload or {}).get("protected_spans_count") or 0), missing_spans(case.prompt, translation, improved), has_internal_placeholder_leak(translation + improved, case.prompt), has_internal_instruction_leak(improved, case.prompt + translation), is_meta_prompt(improved), bool((improve_payload or {}).get("improvement_retry_used")), optimizer._cyrillic_count(translation), optimizer._cyrillic_count(improved), warnings, translation, improved, translation_seconds, improve_seconds, translator_provider, analyzer_provider, translator_model, analyzer_model, error=error)


def _issue_counts(summary: dict[str, Any], total_operations: int) -> dict[str, int]:
    total = int(summary.get("total") or 0)
    return {
        "incomplete_operations": max(0, total_operations - total),
        "translation_failed": int(summary.get("translation_failed") or 0),
        "exception": int(summary.get("exception") or 0),
        "degraded": int(summary.get("degraded") or 0),
        "translation_rejected": int(summary.get("translation_rejected") or 0),
        "confidence_failed": int(summary.get("confidence_failed_count") or 0),
        "protected_span_failures": int(summary.get("protected_span_failures") or 0),
        "placeholder_leaks": int(summary.get("placeholder_leaks") or 0),
        "internal_instruction_leaks": int(summary.get("internal_instruction_leaks") or 0),
        "meta_prompt_outputs": int(summary.get("meta_prompt_outputs") or 0),
    }


def _confidence_values(result: CaseResult) -> list[float]:
    values = [confidence_value(item) for item in [result.translation_confidence, result.improve_confidence, result.overall_confidence]]
    return [value for value in values if value is not None]


def _result_counts(results: list[CaseResult]) -> dict[str, int]:
    return {
        "translation_failed": sum(result.status == "translation_failed" for result in results),
        "exception": sum(result.status == "exception" for result in results),
        "degraded": sum(result.status == "degraded" for result in results),
        "translation_rejected": sum(result.status == "translation_rejected" for result in results),
        "protected_span_failures": sum(bool(result.missing_protected_spans) for result in results),
        "placeholder_leaks": sum(result.placeholder_leak for result in results),
        "internal_instruction_leaks": sum(result.internal_instruction_leak for result in results),
        "meta_prompt_outputs": sum(result.meta_prompt_output for result in results),
        "confidence_failed_count": sum(_confidence_failed(result) for result in results),
    }


def _confidence_failed(result: CaseResult) -> int:
    return sum(isinstance(item, dict) and item.get("status") == "failed" for item in [result.translation_confidence, result.improve_confidence, result.overall_confidence])

from __future__ import annotations

import statistics
from dataclasses import asdict
from typing import Any

from rus_to_prompt_confidence_semantics import (
    canonical_confidence_status,
    confidence_failed,
    confidence_value,
    hard_confidence_cap_reason,
    normalized_confidence_number,
    raw_confidence_value,
)
from rus_to_prompt_stress_models import CaseResult, PromptCase

import soma_language_optimizer as optimizer  # noqa: E402


def missing_spans(prompt: str, *outputs: str) -> list[str]:
    protected = optimizer.protect_spans(prompt)
    combined = "\n".join(outputs)
    return [span for span in protected.spans if span and span not in combined]


def has_internal_placeholder_leak(text: str, source: str) -> bool:
    return "__SOMA_PROTECTED_SPAN_" in (text or "") and "__SOMA_PROTECTED_SPAN_" not in (source or "")


def has_internal_instruction_leak(text: str, source: str = "") -> bool:
    reason = improved_prompt_sanity_error(source, text)
    if reason:
        return "internal instruction" in reason or "repair metadata" in reason
    lowered = (text or "").lower()
    return any(marker in lowered for marker in ["return only the improved prompt", "rewrite the user's request", "hidden system prompt"])


def is_meta_prompt(text: str) -> bool:
    if looks_like_reasoning_transcript(text):
        return True
    reason = improved_prompt_sanity_error("", text)
    if reason:
        return "meta-prompt" in reason or "assistant reasoning" in reason or "repair metadata" in reason
    lowered = (text or "").strip().lower()
    return lowered.startswith(("create a prompt", "create a task prompt", "generate a prompt"))


def looks_like_reasoning_transcript(text: str) -> bool:
    lowered = (text or "").strip().lower()
    if any(marker in lowered for marker in ("<think>", "</think>", "<reasoning>", "</reasoning>")):
        return True
    starters = ("hmm,", "we are given", "i need to", "i should", "the user is asking", "looking at the original", "let me")
    if lowered.startswith(starters):
        return True
    return any(marker in lowered for marker in ["rejected prompt rewrite", "the previous rewrite", "the key issue was", "failure reason"])


def improved_prompt_sanity_error(source: str, improved: str) -> str | None:
    return optimizer._improved_prompt_sanity_error(source or "", improved or "")


def confidence_local_checks(source_prompt: str, result: CaseResult) -> dict[str, Any]:
    sanity_source = "\n".join(part for part in [source_prompt, result.translation] if part)
    return {
        "improved_prompt_sanity_error": improved_prompt_sanity_error(sanity_source, result.improved_prompt),
        "translation_prompt_rewrite": translation_prompt_rewrite_reason(result.translation),
        "internal_instruction_leak": result.internal_instruction_leak,
        "meta_prompt_output": result.meta_prompt_output,
        "placeholder_leak": result.placeholder_leak,
        "missing_protected_spans": result.missing_protected_spans,
        "cyrillic_in_translation": result.cyrillic_in_translation,
        "cyrillic_in_improved": result.cyrillic_in_improved,
    }


def failed_confidence_result(model: str, stage: str, error: str, reasoning_effort: str | None = None, provider: str = "codex") -> dict[str, Any]:
    payload = {"provider": provider, "model": model, "stage": stage, "status": "failed", "confidence": None, "verdict": "fail", "warnings": [error], "error": error}
    if reasoning_effort:
        payload["reasoning_effort"] = reasoning_effort
    return payload


def translation_confidence_allows_improve(confidence: dict[str, Any] | None, threshold: float) -> bool:
    value = confidence_value(confidence)
    return bool(confidence and confidence.get("status") != "failed" and confidence.get("verdict") != "fail" and value is not None and value >= threshold)


def translation_rejection_reason(confidence: dict[str, Any] | None, threshold: float) -> str:
    value = confidence_value(confidence)
    if confidence is None or confidence.get("status") == "failed":
        return "Translation confidence check failed; skipped improver stage."
    if confidence.get("verdict") == "fail":
        reasons = confidence.get("deterministic_confidence_cap_reasons") if isinstance(confidence.get("deterministic_confidence_cap_reasons"), list) else []
        reason = str(reasons[0]) if reasons else "confidence verdict failed"
        return f"Translation confidence failed deterministic gate: {reason}; skipped improver stage."
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
        return canonicalize_confidence_payload(capped)
    cap_value = min(value for value, _reason in caps)
    reasons = [reason for _value, reason in caps]
    raw_value = raw_confidence_value(capped)
    if raw_value is not None and "raw_confidence" not in capped:
        capped["raw_confidence"] = raw_value
    hard_failed = any(hard_confidence_cap_reason(reason) for reason in reasons)
    if hard_failed:
        capped["confidence"] = None
        capped["status"] = "failed"
        capped["verdict"] = "fail"
        capped["effective_score"] = 0.0
        capped["deterministic_confidence_cap_reasons"] = reasons
        return capped
    current = normalized_confidence_number(capped.get("confidence"))
    if current is None or current > cap_value:
        capped["confidence"] = cap_value
    capped["status"] = "review"
    capped["verdict"] = "review"
    capped["effective_score"] = confidence_value(capped)
    capped["deterministic_confidence_cap_reasons"] = reasons
    return capped


def canonicalize_confidence_payload(confidence: dict[str, Any]) -> dict[str, Any]:
    canonical = dict(confidence)
    raw_value = raw_confidence_value(canonical)
    if raw_value is not None and "raw_confidence" not in canonical:
        canonical["raw_confidence"] = raw_value
    status = canonical_confidence_status(canonical)
    if status == "failed":
        canonical["status"] = "failed"
        canonical["verdict"] = "fail"
        canonical["confidence"] = None
        canonical["effective_score"] = 0.0
        return canonical
    if status:
        canonical["status"] = status
    if status == "review" and str(canonical.get("verdict") or "").strip().lower() in {"pass", "passed"}:
        canonical["verdict"] = "review"
    usable = confidence_value(canonical)
    if usable is not None:
        canonical["effective_score"] = usable
    return canonical


def deterministic_confidence_caps(result: CaseResult, stage: str) -> list[tuple[float, str]]:
    caps: list[tuple[float, str]] = []
    if result.placeholder_leak:
        caps.append((0.50, "internal placeholder leak"))
    if result.internal_instruction_leak:
        caps.append((0.50, "internal instruction leak"))
    if result.meta_prompt_output:
        caps.append((0.35, "meta prompt or reasoning transcript"))
    if stage in {"improve", "overall"}:
        sanity_reason = improved_prompt_sanity_error(result.translation or "", result.improved_prompt or "")
        if sanity_reason:
            caps.append((0.50, "improved prompt sanity: " + sanity_reason))
    if stage == "translation":
        caps.extend(translation_failure_confidence_caps(result))
        reason = translation_prompt_rewrite_reason(result.translation)
        if reason:
            caps.append((0.50, reason))
    if stage == "translation" and result.cyrillic_in_translation > 0:
        caps.append((0.65, "translation still contains Cyrillic"))
    if result.missing_protected_spans:
        caps.append((0.60, "missing protected spans"))
    if stage == "overall":
        caps.extend(overall_pipeline_confidence_caps(result))
    return caps


def translation_failure_confidence_caps(result: CaseResult) -> list[tuple[float, str]]:
    caps: list[tuple[float, str]] = []
    translation_status = str(result.translation_status or "")
    translation = (result.translation or "").strip()
    warnings = " ".join(str(warning) for warning in (result.warnings or [])).lower()
    failed_statuses = {"failed", "failed_fallback", "exception", "timeout"}
    if not translation:
        caps.append((0.0, "empty translation"))
    if translation_status and translation_status not in {"translated", "original_english"}:
        caps.append((0.20, f"translation failed: {translation_status}"))
    if any(marker in warnings for marker in ("timed out", "timeout", "translation failed", "failed_fallback")):
        caps.append((0.20, "translation failed or timed out"))
    if result.status in {"translation_failed", "translation_rejected"} or translation_status in failed_statuses:
        caps.append((0.20, "translation pipeline failed"))
    return caps


def translation_prompt_rewrite_reason(text: str) -> str | None:
    stripped = (text or "").lstrip()
    if not stripped:
        return None
    first_line = _normalized_prompt_rewrite_line(stripped.splitlines()[0])
    section_prefixes = (
        "task:",
        "requirements:",
        "constraints:",
        "deliverables:",
        "source prompt:",
        "original prompt:",
        "user request:",
        "requested output:",
        "prompt:",
    )
    for prefix in section_prefixes:
        if first_line.startswith(prefix):
            return f"translation output looks like a prompt rewrite ({prefix.rstrip(':')} heading)"

    early = _normalized_prompt_rewrite_line(stripped[:500])
    narrative_starters = (
        "the user wants",
        "the user is asking",
        "the user asked",
        "source prompt",
        "original prompt",
        "rewrite the user's request",
        "create a comprehensive prompt",
    )
    if early.startswith(narrative_starters):
        return "translation output looks like prompt rewrite/meta text"

    section_hits = sum(
        1
        for line in stripped.splitlines()[:8]
        if _normalized_prompt_rewrite_line(line).startswith(("requirements:", "constraints:", "deliverables:", "task:"))
    )
    if section_hits >= 2:
        return "translation output contains prompt rewrite sections"
    return None


def overall_pipeline_confidence_caps(result: CaseResult) -> list[tuple[float, str]]:
    caps: list[tuple[float, str]] = []
    if result.status == "degraded":
        caps.append((0.75, "pipeline status degraded"))
    warnings = [str(warning) for warning in (result.warnings or []) if str(warning).strip()]
    if warnings:
        severe = [warning for warning in warnings if _severe_pipeline_warning(warning)]
        if severe:
            caps.append((0.60, "pipeline warning: " + severe[0][:120]))
        else:
            caps.append((0.95, "pipeline warnings present"))
    if _improved_prompt_fell_back_to_translation(result):
        caps.append((0.50, "improved prompt fell back to translation after failed improve"))
    return caps


def _normalized_prompt_rewrite_line(text: str) -> str:
    normalized = (text or "").strip().lower()
    normalized = normalized.lstrip("#>*_`- \t")
    return normalized.strip()


def _severe_pipeline_warning(warning: str) -> bool:
    lowered = warning.lower()
    markers = (
        "failed:",
        "retry failed",
        "failed retry",
        "prompt improvement failed",
        "improvement failed",
        "protected span",
        "protected placeholders",
        "dropped protected",
        "missing protected",
        "internal instruction",
        "leaked internal",
    )
    return any(marker in lowered for marker in markers)


def _improved_prompt_fell_back_to_translation(result: CaseResult) -> bool:
    translation = (result.translation or "").strip()
    improved = (result.improved_prompt or "").strip()
    if not translation or translation != improved:
        return False
    return result.status != "ok" or result.improve_status not in {None, "ok"}


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
    sanity_source = "\n".join(part for part in [case.prompt, translation] if part)
    improved_sanity = improved_prompt_sanity_error(sanity_source, improved) if improve_payload is not None else None
    if improved_sanity:
        warnings = warnings + ["Improved prompt sanity failed: " + improved_sanity]
        if status == "ok":
            status = "degraded"
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
        "translation_failed": sum(_translation_failed_result(result) for result in results),
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
    return sum(confidence_failed(item) for item in [result.translation_confidence, result.improve_confidence, result.overall_confidence])


def _translation_failed_result(result: CaseResult) -> bool:
    translation_status = str(result.translation_status or "")
    return result.status == "translation_failed" or translation_status in {"failed", "failed_fallback", "exception", "timeout"} or (translation_status and not (result.translation or "").strip())

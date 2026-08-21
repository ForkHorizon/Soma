from __future__ import annotations

import statistics
from typing import Any


LOW_CONFIDENCE_THRESHOLD = 0.75
OK_STATUSES = {
    "ok",
    "pass",
    "passed",
    "approved",
    "accepted",
    "success",
    "succeeded",
    "completed",
    "complete",
    "evaluated",
    "translation_only",
    "translated",
    "improved",
}
REVIEW_STATUSES = {
    "review",
    "degraded",
    "warning",
    "warn",
    "uncertain",
    "low",
    "poor",
}
FAILED_STATUSES = {
    "failed",
    "fail",
    "failure",
    "error",
    "exception",
    "rejected",
    "reject",
    "timeout",
    "poor_translation",
}
FIXED_SCORE_AXES = {
    "translation": ["intent_preservation", "english_quality", "protected_span_preservation", "no_invention"],
    "improve": ["intent_preservation", "actionability", "concision", "no_invention"],
    "overall": [
        "intent_preservation",
        "english_quality",
        "protected_span_preservation",
        "actionability",
        "concision",
        "no_invention",
    ],
}
SCORE_WEIGHTS = {
    "intent_preservation": 0.28,
    "english_quality": 0.16,
    "protected_span_preservation": 0.22,
    "actionability": 0.14,
    "concision": 0.08,
    "no_invention": 0.12,
}


def normalized_confidence_number(value: Any) -> float | None:
    if not isinstance(value, (int, float)):
        return None
    return min(1.0, max(0.0, float(value)))


def confidence_cap_reasons(confidence: dict[str, Any] | None) -> list[str]:
    if not isinstance(confidence, dict):
        return []
    reasons = confidence.get("deterministic_confidence_cap_reasons")
    if not isinstance(reasons, list):
        reasons = confidence.get("deterministic_cap_reasons")
    if not isinstance(reasons, list):
        return []
    return [str(reason) for reason in reasons if str(reason or "").strip()]


def hard_confidence_cap_reason(reason: str) -> bool:
    lowered = reason.lower()
    hard_markers = (
        "internal placeholder leak",
        "internal instruction leak",
        "meta prompt",
        "reasoning transcript",
        "prompt rewrite",
        "empty translation",
        "translation failed",
        "translation pipeline failed",
        "missing protected spans",
        "improved prompt sanity",
        "fell back to translation",
    )
    return any(marker in lowered for marker in hard_markers)


def has_hard_confidence_cap(confidence: dict[str, Any] | None) -> bool:
    return any(hard_confidence_cap_reason(reason) for reason in confidence_cap_reasons(confidence))


def raw_confidence_value(confidence: dict[str, Any] | None) -> float | None:
    if not isinstance(confidence, dict):
        return None
    raw = normalized_confidence_number(confidence.get("raw_confidence"))
    if raw is not None:
        return raw
    return normalized_confidence_number(confidence.get("confidence"))


def canonical_confidence_status(confidence: dict[str, Any] | None) -> str | None:
    if not isinstance(confidence, dict):
        return None
    value = normalized_confidence_number(confidence.get("confidence"))
    raw = str(confidence.get("status") or "").strip().lower()
    verdict = str(confidence.get("verdict") or "").strip().lower()
    if has_hard_confidence_cap(confidence) or raw in FAILED_STATUSES or verdict in FAILED_STATUSES:
        return "failed"
    if value is None:
        return "review"
    if value < LOW_CONFIDENCE_THRESHOLD:
        return "review"
    if raw in REVIEW_STATUSES or verdict in REVIEW_STATUSES:
        return "review"
    if raw in OK_STATUSES or verdict in {"pass", "passed", "ok"}:
        return "ok"
    return "review"


def confidence_failed(confidence: dict[str, Any] | None) -> bool:
    return canonical_confidence_status(confidence) == "failed"


def confidence_value(confidence: dict[str, Any] | None) -> float | None:
    if not isinstance(confidence, dict) or confidence_failed(confidence):
        return None
    value = normalized_confidence_number(confidence.get("confidence"))
    return value


def effective_confidence_score(confidence: dict[str, Any] | None) -> float | None:
    if not isinstance(confidence, dict):
        return None
    if confidence_failed(confidence):
        return 0.0
    value = confidence_value(confidence)
    if value is not None:
        return value
    explicit = normalized_confidence_number(confidence.get("effective_score"))
    return explicit


def normalized_score_map(scores: Any, stage: str) -> dict[str, float]:
    if not isinstance(scores, dict):
        return {}
    axes = FIXED_SCORE_AXES.get(stage, FIXED_SCORE_AXES["overall"])
    normalized: dict[str, float] = {}
    for axis in axes:
        value = scores.get(axis)
        if not isinstance(value, (int, float)):
            continue
        numeric = float(value)
        if 0.0 <= numeric <= 1.0:
            numeric *= 5.0
        normalized[axis] = min(5.0, max(0.0, numeric))
    return normalized


def calibrated_confidence_from_scores(raw: float | None, scores: dict[str, float], stage: str) -> float | None:
    if not scores:
        return raw
    axes = FIXED_SCORE_AXES.get(stage, FIXED_SCORE_AXES["overall"])
    present = [axis for axis in axes if axis in scores]
    if not present:
        return raw
    weights = [SCORE_WEIGHTS.get(axis, 0.10) for axis in present]
    total_weight = sum(weights) or 1.0
    weighted = sum((scores[axis] / 5.0) * SCORE_WEIGHTS.get(axis, 0.10) for axis in present) / total_weight
    score_ceiling = min(1.0, max(0.0, weighted))
    return min(raw, score_ceiling) if raw is not None else score_ceiling


def average_usable_confidence(confidences: list[dict[str, Any]]) -> float | None:
    values = [value for confidence in confidences if (value := confidence_value(confidence)) is not None]
    return statistics.mean(values) if values else None

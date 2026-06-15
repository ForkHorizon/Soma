from __future__ import annotations

import statistics
from typing import Any

from rus_to_prompt_confidence_semantics import (
    confidence_cap_reasons,
    confidence_failed as semantic_confidence_failed,
    confidence_value as semantic_confidence_value,
)


LOW_CONFIDENCE_THRESHOLD = 0.75
CODEX_MODELS = {
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


def confidence_value(confidence: dict[str, Any] | None) -> float | None:
    return semantic_confidence_value(confidence)


def confidence_failed(confidence: dict[str, Any] | None) -> bool:
    return semantic_confidence_failed(confidence)


def confidence_warnings(confidence: dict[str, Any] | None) -> list[str]:
    if not isinstance(confidence, dict):
        return []
    warnings = []
    if isinstance(confidence.get("warnings"), list):
        warnings.extend(str(item) for item in confidence.get("warnings") if str(item or "").strip())
    warnings.extend("Cap: " + reason for reason in confidence_cap_reasons(confidence))
    return warnings


def provider_for_model(model: str, explicit: str | None = None) -> str:
    normalized = (model or "").strip().lower()
    if normalized.startswith("gpt-oss"):
        return "Local"
    explicit_clean = (explicit or "").strip().lower()
    if explicit_clean in {"local", "codex", "gemini", "deepseek"}:
        return {"codex": "Codex", "deepseek": "DeepSeek"}.get(explicit_clean, explicit_clean.capitalize())
    if normalized in CODEX_MODELS or normalized.startswith(("gpt-", "codex-", "o1", "o3", "o4")):
        return "Codex"
    if normalized.startswith(("gemini-", "gemma-4-", "auto-gemini")):
        return "Gemini"
    if normalized.startswith("deepseek-"):
        return "DeepSeek"
    return "Local" if normalized else "Unknown"


def median_or_none(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


def mean_or_none(values: list[float]) -> float | None:
    return statistics.mean(values) if values else None


def sorted_recent_runs(run_items: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    rows = [_recent_run_row(run_dir, item) for run_dir, item in run_items.items()]
    return sorted(rows, key=lambda row: row.get("finished_at") or "", reverse=True)[:8]


def _recent_run_row(run_dir: str, item: dict[str, Any]) -> dict[str, Any]:
    confidence_values = item.get("confidence_values") or []
    quality_values = item.get("quality_values") or []
    return {
        "run_dir": run_dir,
        "finished_at": item.get("finished_at"),
        "attempts": int(item.get("attempts") or 0),
        "quality_score": mean_or_none(quality_values),
        "avg_confidence": mean_or_none(confidence_values),
        "low_confidence_count": int(item.get("low_confidence_count") or 0),
        "failed_count": int(item.get("failed_count") or 0),
    }

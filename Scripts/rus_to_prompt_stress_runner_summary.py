from __future__ import annotations

import statistics
from collections import Counter
from typing import Any

from rus_to_prompt_confidence_semantics import confidence_failed, confidence_value, effective_confidence_score
from rus_to_prompt_stress_models import TRANSLATION_ONLY_ANALYZER_MODEL, provider_for_stage_model


def summary_metadata(args, translators, analyzers, total_operations: int, results) -> dict[str, Any]:
    return {
        "benchmark_mode": args.benchmark_mode,
        "total_operations": total_operations,
        "translator_models": translators,
        "analyzer_models": analyzers if args.benchmark_mode != "translation" else [TRANSLATION_ONLY_ANALYZER_MODEL],
        "confidence_referee": args.confidence_referee,
        "confidence_model": args.confidence_model,
        "translator_providers": {model: provider_for_stage_model(model, args.translator_provider) for model in translators},
        "analyzer_providers": {model: provider_for_stage_model(model, args.analyzer_provider) for model in analyzers},
        "model_combinations": model_combinations(results),
        "external_error_counts": external_error_counts(results),
    }


def model_combinations(results) -> list[dict[str, Any]]:
    groups: dict[tuple[str, str], list[Any]] = {}
    for result in results:
        key = (str(result.translator_model or "none"), str(result.analyzer_model or "none"))
        groups.setdefault(key, []).append(result)
    rows = [_combination_row(translator, analyzer, items) for (translator, analyzer), items in groups.items()]
    return sorted(rows, key=lambda row: ((row.get("quality_score") if row.get("quality_score") is not None else -1), -int(row.get("failed") or 0), row["combo_id"]), reverse=True)


def _combination_row(translator: str, analyzer: str, items) -> dict[str, Any]:
    warnings = Counter(warning for result in items for warning in (result.warnings or []))
    return {
        "combo_id": f"{translator} -> {analyzer}",
        "translator_model": translator,
        "analyzer_model": analyzer,
        "total": len(items),
        "ok": sum(result.status in {"ok", "translation_only"} for result in items),
        "degraded": sum(result.status == "degraded" for result in items),
        "failed": sum(result.status not in {"ok", "translation_only", "degraded"} for result in items),
        "translation_confidence": confidence_aggregate([result.translation_confidence for result in items]),
        "improve_confidence": confidence_aggregate([result.improve_confidence for result in items]),
        "overall_confidence": confidence_aggregate([result.overall_confidence for result in items]),
        "quality_score": quality_score(items),
        "low_confidence_count": low_confidence_count(items),
        "duration_seconds": sum(float(result.seconds or 0) for result in items),
        "top_warnings": [warning for warning, _count in warnings.most_common(5)],
        "low_cases": low_cases(items),
    }


def confidence_aggregate(confidences) -> dict[str, Any]:
    items = [confidence for confidence in confidences if isinstance(confidence, dict)]
    values = [
        value
        for confidence in items
        if (value := confidence_value(confidence)) is not None
    ]
    by_status = Counter("failed" if confidence_failed(confidence) else str(confidence.get("status") or "unknown") for confidence in items)
    return {
        "count": len(values),
        "avg": statistics.mean(values) if values else None,
        "median": statistics.median(values) if values else None,
        "min": min(values) if values else None,
        "failed": sum(confidence_failed(confidence) for confidence in items),
        "by_status": dict(by_status),
    }


def quality_score(items) -> float | None:
    scores: list[float] = []
    for result in items:
        confidence = result.overall_confidence or result.improve_confidence or result.translation_confidence
        value = effective_confidence_score(confidence)
        if value is not None:
            scores.append(value)
        elif result.status not in {"ok", "translation_only", "degraded"}:
            scores.append(0.0)
    return statistics.mean(scores) if scores else None


def low_confidence_count(items) -> int:
    count = 0
    for result in items:
        confidences = [
            confidence
            for confidence in [result.translation_confidence, result.improve_confidence, result.overall_confidence]
            if isinstance(confidence, dict)
        ]
        if any(confidence_failed(confidence) for confidence in confidences):
            count += 1
            continue
        values = [confidence_value(confidence) for confidence in confidences]
        if any(value is None or (isinstance(value, (int, float)) and value < 0.75) for value in values):
            count += 1
    return count


def low_cases(items) -> list[dict[str, Any]]:
    rows = []
    for result in items:
        confidence_map, failed = _case_confidence_flags(result)
        if failed or any(value < 0.75 for value in confidence_map.values()):
            rows.append({"id": result.id, "category": result.category, "status": result.status, "confidences": confidence_map, "failed_stages": failed, "warnings": list(result.warnings or [])[:4]})
    return rows[:8]


def _case_confidence_flags(result) -> tuple[dict[str, float], list[str]]:
    confidence_map: dict[str, float] = {}
    failed: list[str] = []
    for name, confidence in [("translation", result.translation_confidence), ("improve", result.improve_confidence), ("overall", result.overall_confidence)]:
        if not isinstance(confidence, dict):
            continue
        if confidence_failed(confidence):
            failed.append(name)
            continue
        value = confidence_value(confidence)
        if value is not None:
            confidence_map[name] = value
    return confidence_map, failed


def external_error_counts(results) -> dict[str, int]:
    counts = Counter()
    for result in results:
        for confidence in [result.translation_confidence, result.improve_confidence, result.overall_confidence]:
            if isinstance(confidence, dict) and confidence.get("error_type"):
                counts[str(confidence["error_type"])] += 1
    return dict(counts)

from __future__ import annotations

import json
import statistics
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from rus_to_prompt_stats_bucket import RoleBucket
from rus_to_prompt_stats_core import confidence_failed, confidence_value, confidence_warnings, provider_for_model
from rus_to_prompt_stress_results import improved_prompt_sanity_error, looks_like_reasoning_transcript


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        decoded = json.loads(stripped)
        if isinstance(decoded, dict):
            rows.append(decoded)
    return rows


def load_summary(path: Path) -> dict[str, Any]:
    decoded = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    return decoded if isinstance(decoded, dict) else {}


def run_provider_maps(summary: dict[str, Any]) -> tuple[dict[str, str], dict[str, str]]:
    translator = summary.get("translator_providers")
    analyzer = summary.get("analyzer_providers")
    return (
        translator if isinstance(translator, dict) else {},
        analyzer if isinstance(analyzer, dict) else {},
    )


def aggregate_stats(stress_dir: Path) -> dict[str, Any]:
    translation_buckets: dict[str, RoleBucket] = {}
    improver_buckets: dict[str, RoleBucket] = {}
    scanned_runs = 0
    skipped_runs = 0
    for run in _iter_runs(stress_dir):
        if run is None:
            skipped_runs += 1
            continue
        scanned_runs += 1
        _aggregate_run(run, translation_buckets, improver_buckets)
    return _payload(stress_dir, scanned_runs, skipped_runs, translation_buckets, improver_buckets)


def _iter_runs(stress_dir: Path) -> list[dict[str, Any] | None]:
    summary_paths = sorted(stress_dir.glob("**/summary.json")) if stress_dir.exists() else []
    return [_load_run(summary_path) for summary_path in summary_paths]


def _load_run(summary_path: Path) -> dict[str, Any] | None:
    results_path = summary_path.parent / "results.jsonl"
    if not results_path.exists():
        return None
    try:
        summary = load_summary(summary_path)
        rows = read_jsonl(results_path)
    except Exception:
        return None
    if not rows:
        return None
    translator_providers, analyzer_providers = run_provider_maps(summary)
    return {
        "run_dir": str(summary_path.parent),
        "finished_at": str(summary.get("finished_at") or ""),
        "translator_providers": translator_providers,
        "analyzer_providers": analyzer_providers,
        "rows": rows,
    }


def _aggregate_run(
    run: dict[str, Any],
    translation_buckets: dict[str, RoleBucket],
    improver_buckets: dict[str, RoleBucket],
) -> None:
    translation_attempts: dict[tuple[str, str, str, str], dict[str, Any]] = {}
    for row in run["rows"]:
        _collect_translation_attempt(run, row, translation_attempts)
        if _should_record_improver(row):
            _record_improver_attempt(run, row, improver_buckets)
    _finalize_translation_attempts(run, translation_attempts, translation_buckets)


def _collect_translation_attempt(
    run: dict[str, Any],
    row: dict[str, Any],
    attempts: dict[tuple[str, str, str, str], dict[str, Any]],
) -> None:
    translator_model = str(row.get("translator_model") or "unknown")
    analyzer_model = str(row.get("analyzer_model") or "unknown")
    case_id = str(row.get("id") or "unknown")
    key = (run["run_dir"], case_id, translator_model, str(row.get("translation") or ""))
    attempt = attempts.setdefault(key, _translation_attempt(row, translator_model, case_id))
    attempt["related_models"].add(analyzer_model)
    confidence = row.get("translation_confidence")
    value = confidence_value(confidence if isinstance(confidence, dict) else None)
    if value is not None:
        attempt["confidences"].append(value)
    attempt["confidence_failed"] = attempt["confidence_failed"] or confidence_failed(confidence if isinstance(confidence, dict) else None)
    attempt["translation_failed"] = attempt["translation_failed"] or _translation_failed(row)
    attempt["degraded"] = attempt["degraded"] or str(row.get("translation_status") or "") == "degraded"
    attempt["warnings"].extend(confidence_warnings(confidence if isinstance(confidence, dict) else None))
    if attempt["translation_failed"]:
        attempt["warnings"].extend(row.get("warnings") or [])


def _translation_attempt(row: dict[str, Any], model: str, case_id: str) -> dict[str, Any]:
    return {
        "model": model,
        "case_id": case_id,
        "category": row.get("category"),
        "confidences": [],
        "confidence_failed": False,
        "translation_failed": False,
        "degraded": False,
        "seconds": row.get("translation_seconds"),
        "warnings": [],
        "related_models": set(),
    }


def _translation_failed(row: dict[str, Any]) -> bool:
    status = str(row.get("status") or "")
    translation_status = str(row.get("translation_status") or "")
    return status == "translation_failed" or translation_status in {"failed", "failed_fallback", "exception", "timeout"} or (translation_status and not str(row.get("translation") or "").strip())


def _should_record_improver(row: dict[str, Any]) -> bool:
    is_translation_only = (
        str(row.get("analyzer_model") or "") == "translation-only"
        or str(row.get("benchmark_mode") or "") == "translation"
    )
    return str(row.get("status") or "") != "translation_failed" and not is_translation_only


def _record_improver_attempt(run: dict[str, Any], row: dict[str, Any], buckets: dict[str, RoleBucket]) -> None:
    improver_model = str(row.get("analyzer_model") or "unknown")
    explicit = str(row.get("analyzer_provider") or run["analyzer_providers"].get(improver_model) or "")
    bucket = buckets.setdefault(improver_model, RoleBucket(improver_model, provider_for_model(improver_model, explicit)))
    confidence_dict = _effective_improve_confidence(row)
    row_status = str(row.get("status") or "")
    improve_status = str(row.get("improve_status") or row_status)
    bucket.add_attempt(
        run_dir=run["run_dir"],
        finished_at=run["finished_at"],
        case_id=str(row.get("id") or "unknown"),
        category=row.get("category"),
        confidence=confidence_value(confidence_dict),
        confidence_failed_value=confidence_failed(confidence_dict),
        status=improve_status,
        degraded=row_status == "degraded" or improve_status == "degraded",
        pipeline_failed=improve_status not in {"ok", "degraded"} and row_status not in {"ok", "degraded"},
        seconds=row.get("improve_seconds"),
        warnings=_improver_warnings(row, confidence_dict, row_status, improve_status),
        related_model=str(row.get("translator_model") or "unknown"),
    )


def _improver_warnings(
    row: dict[str, Any],
    confidence: dict[str, Any] | None,
    row_status: str,
    improve_status: str,
) -> list[str]:
    warnings = confidence_warnings(confidence)
    if row_status != "ok" or improve_status != "ok":
        warnings += list(row.get("warnings") or [])
    return warnings


def _effective_improve_confidence(row: dict[str, Any]) -> dict[str, Any] | None:
    confidence = row.get("improve_confidence")
    confidence_dict = confidence if isinstance(confidence, dict) else None
    reason = _row_improved_prompt_sanity_error(row)
    if not reason and not bool(row.get("internal_instruction_leak")) and not bool(row.get("meta_prompt_output")):
        return confidence_dict
    capped = dict(confidence_dict or {})
    raw_value = confidence_value(confidence_dict)
    if raw_value is not None and "raw_confidence" not in capped:
        capped["raw_confidence"] = raw_value
    capped["confidence"] = None
    capped["status"] = "failed"
    capped["verdict"] = "fail"
    capped["effective_score"] = 0.0
    warnings = confidence_warnings(capped)
    warning = "Deterministic stats cap: " + (reason or "stored internal instruction leak")
    if warning not in warnings:
        warnings.insert(0, warning)
    capped["warnings"] = warnings[:6]
    return capped


def _row_improved_prompt_sanity_error(row: dict[str, Any]) -> str | None:
    improved = str(row.get("improved_prompt") or "")
    if not improved:
        return None
    source = str(row.get("translation") or "")
    return improved_prompt_sanity_error(source, improved) or ("prompt improvement returned assistant reasoning instead of the direct task" if looks_like_reasoning_transcript(improved) else None)


def _finalize_translation_attempts(
    run: dict[str, Any],
    attempts: dict[tuple[str, str, str, str], dict[str, Any]],
    buckets: dict[str, RoleBucket],
) -> None:
    for attempt in attempts.values():
        model = str(attempt["model"])
        bucket = buckets.setdefault(model, RoleBucket(model, provider_for_model(model, run["translator_providers"].get(model))))
        values = [float(value) for value in attempt["confidences"]]
        averaged = statistics.mean(values) if values else None
        bucket.add_attempt(
            run_dir=run["run_dir"],
            finished_at=run["finished_at"],
            case_id=str(attempt["case_id"]),
            category=attempt.get("category"),
            confidence=averaged,
            confidence_failed_value=bool(attempt["confidence_failed"]),
            status="translation_failed" if attempt["translation_failed"] else "ok",
            degraded=bool(attempt["degraded"]),
            pipeline_failed=bool(attempt["translation_failed"]),
            seconds=attempt.get("seconds"),
            warnings=list(attempt["warnings"]),
            related_model=", ".join(sorted(attempt["related_models"])) if attempt["related_models"] else None,
        )


def _payload(
    stress_dir: Path,
    scanned_runs: int,
    skipped_runs: int,
    translation_buckets: dict[str, RoleBucket],
    improver_buckets: dict[str, RoleBucket],
) -> dict[str, Any]:
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "stress_dir": str(stress_dir),
        "scanned_runs": scanned_runs,
        "skipped_runs": skipped_runs,
        "translation_models": _sort_rows([bucket.to_json() for bucket in translation_buckets.values()]),
        "improver_models": _sort_rows([bucket.to_json() for bucket in improver_buckets.values()]),
    }


def _sort_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(
        rows,
        key=lambda item: (
            item["quality_score"] if item.get("quality_score") is not None else -1,
            -int(item["problem_count"] or 0),
            -int(item["confidence_failed_count"] or 0),
            -int(item["pipeline_failed_count"] or 0),
            -int(item["low_confidence_count"] or 0),
            item["median_confidence"] if item["median_confidence"] is not None else -1,
            int(item["attempts"] or 0),
        ),
        reverse=True,
    )

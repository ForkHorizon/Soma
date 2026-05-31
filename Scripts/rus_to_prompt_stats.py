#!/usr/bin/env python3
"""Aggregate Rus to Prompt model quality across saved stress-test logs."""
from __future__ import annotations

import argparse
import json
import statistics
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
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
    if not isinstance(confidence, dict):
        return None
    if str(confidence.get("status") or "") == "failed":
        return None
    value = confidence.get("confidence")
    return float(value) if isinstance(value, (int, float)) else None


def confidence_failed(confidence: dict[str, Any] | None) -> bool:
    return isinstance(confidence, dict) and str(confidence.get("status") or "") == "failed"


def confidence_warnings(confidence: dict[str, Any] | None) -> list[str]:
    if not isinstance(confidence, dict) or not isinstance(confidence.get("warnings"), list):
        return []
    return [str(item) for item in confidence.get("warnings") if str(item or "").strip()]


def provider_for_model(model: str, explicit: str | None = None) -> str:
    explicit_clean = (explicit or "").strip().lower()
    if explicit_clean in {"local", "codex", "gemini"}:
        return explicit_clean.capitalize() if explicit_clean != "codex" else "Codex"
    normalized = (model or "").strip().lower()
    if (
        normalized in CODEX_MODELS
        or normalized.startswith("gpt-")
        or normalized.startswith("codex-")
        or normalized.startswith("o1")
        or normalized.startswith("o3")
        or normalized.startswith("o4")
    ):
        return "Codex"
    if normalized.startswith("gemini-") or normalized.startswith("gemma-4-") or normalized.startswith("auto-gemini"):
        return "Gemini"
    if normalized:
        return "Local"
    return "Unknown"


def median_or_none(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


def mean_or_none(values: list[float]) -> float | None:
    return statistics.mean(values) if values else None


def sorted_recent_runs(run_items: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    rows = []
    for run_dir, item in run_items.items():
        confidence_values = item.get("confidence_values") or []
        rows.append(
            {
                "run_dir": run_dir,
                "finished_at": item.get("finished_at"),
                "attempts": int(item.get("attempts") or 0),
                "avg_confidence": mean_or_none(confidence_values),
                "low_confidence_count": int(item.get("low_confidence_count") or 0),
                "failed_count": int(item.get("failed_count") or 0),
            }
        )
    return sorted(rows, key=lambda row: row.get("finished_at") or "", reverse=True)[:8]


@dataclass
class RoleBucket:
    model: str
    provider: str
    attempts: int = 0
    confidence_values: list[float] = field(default_factory=list)
    low_confidence_count: int = 0
    confidence_failed_count: int = 0
    pipeline_failed_count: int = 0
    degraded_count: int = 0
    seconds_values: list[float] = field(default_factory=list)
    last_tested_at: str | None = None
    worst_cases: list[dict[str, Any]] = field(default_factory=list)
    warning_counts: Counter[str] = field(default_factory=Counter)
    recent_runs: dict[str, dict[str, Any]] = field(default_factory=dict)

    def add_attempt(
        self,
        *,
        run_dir: str,
        finished_at: str | None,
        case_id: str,
        category: str | None,
        confidence: float | None,
        confidence_failed_value: bool,
        status: str,
        degraded: bool,
        pipeline_failed: bool,
        seconds: float | None,
        warnings: list[str],
        related_model: str | None = None,
    ) -> None:
        self.attempts += 1
        if finished_at and (self.last_tested_at is None or finished_at > self.last_tested_at):
            self.last_tested_at = finished_at
        if confidence is not None:
            self.confidence_values.append(confidence)
            if confidence < LOW_CONFIDENCE_THRESHOLD:
                self.low_confidence_count += 1
        elif confidence_failed_value:
            self.confidence_failed_count += 1
        if pipeline_failed:
            self.pipeline_failed_count += 1
        if degraded:
            self.degraded_count += 1
        if isinstance(seconds, (int, float)):
            self.seconds_values.append(float(seconds))
        for warning in warnings[:5]:
            clean = str(warning or "").strip()
            if clean:
                self.warning_counts[clean] += 1

        run_item = self.recent_runs.setdefault(
            run_dir,
            {
                "finished_at": finished_at,
                "attempts": 0,
                "confidence_values": [],
                "low_confidence_count": 0,
                "failed_count": 0,
            },
        )
        run_item["attempts"] += 1
        if confidence is not None:
            run_item["confidence_values"].append(confidence)
            if confidence < LOW_CONFIDENCE_THRESHOLD:
                run_item["low_confidence_count"] += 1
        if confidence_failed_value or pipeline_failed:
            run_item["failed_count"] += 1

        if confidence is None and not confidence_failed_value and not pipeline_failed and not degraded:
            return
        effective = confidence if confidence is not None else -1.0
        if effective < LOW_CONFIDENCE_THRESHOLD or confidence_failed_value or pipeline_failed or degraded:
            self.worst_cases.append(
                {
                    "run_dir": run_dir,
                    "case_id": case_id,
                    "category": category,
                    "confidence": confidence,
                    "confidence_failed": confidence_failed_value,
                    "status": status,
                    "related_model": related_model,
                    "warnings": warnings[:3],
                }
            )

    def to_json(self) -> dict[str, Any]:
        worst = sorted(
            self.worst_cases,
            key=lambda item: (
                item.get("confidence") is not None,
                item.get("confidence") if item.get("confidence") is not None else -1.0,
            ),
        )[:10]
        return {
            "model": self.model,
            "provider": self.provider,
            "attempts": self.attempts,
            "confidence_count": len(self.confidence_values),
            "avg_confidence": mean_or_none(self.confidence_values),
            "median_confidence": median_or_none(self.confidence_values),
            "min_confidence": min(self.confidence_values) if self.confidence_values else None,
            "low_confidence_count": self.low_confidence_count,
            "confidence_failed_count": self.confidence_failed_count,
            "pipeline_failed_count": self.pipeline_failed_count,
            "degraded_count": self.degraded_count,
            "avg_seconds": mean_or_none(self.seconds_values),
            "last_tested_at": self.last_tested_at,
            "worst_cases": worst,
            "top_warnings": [
                {"warning": warning, "count": count}
                for warning, count in self.warning_counts.most_common(8)
            ],
            "recent_runs": sorted_recent_runs(self.recent_runs),
        }


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

    summary_paths = sorted(stress_dir.glob("**/summary.json")) if stress_dir.exists() else []
    for summary_path in summary_paths:
        run_dir_path = summary_path.parent
        results_path = run_dir_path / "results.jsonl"
        if not results_path.exists():
            skipped_runs += 1
            continue
        try:
            summary = load_summary(summary_path)
            rows = read_jsonl(results_path)
        except Exception:
            skipped_runs += 1
            continue
        if not rows:
            skipped_runs += 1
            continue

        scanned_runs += 1
        run_dir = str(run_dir_path)
        finished_at = str(summary.get("finished_at") or "")
        translator_providers, analyzer_providers = run_provider_maps(summary)

        translation_attempts: dict[tuple[str, str, str, str], dict[str, Any]] = {}
        for row in rows:
            translator_model = str(row.get("translator_model") or "unknown")
            analyzer_model = str(row.get("analyzer_model") or "unknown")
            translation = str(row.get("translation") or "")
            case_id = str(row.get("id") or "unknown")
            key = (run_dir, case_id, translator_model, translation)
            attempt = translation_attempts.setdefault(
                key,
                {
                    "model": translator_model,
                    "case_id": case_id,
                    "category": row.get("category"),
                    "confidences": [],
                    "confidence_failed": False,
                    "translation_failed": False,
                    "degraded": False,
                    "seconds": row.get("translation_seconds"),
                    "warnings": [],
                    "related_models": set(),
                },
            )
            attempt["related_models"].add(analyzer_model)
            confidence = row.get("translation_confidence")
            value = confidence_value(confidence if isinstance(confidence, dict) else None)
            if value is not None:
                attempt["confidences"].append(value)
            if confidence_failed(confidence if isinstance(confidence, dict) else None):
                attempt["confidence_failed"] = True
            if str(row.get("status") or "") == "translation_failed" or str(row.get("translation_status") or "") in {"failed", "exception"}:
                attempt["translation_failed"] = True
            if str(row.get("translation_status") or "") == "degraded":
                attempt["degraded"] = True
            attempt["warnings"].extend(confidence_warnings(confidence if isinstance(confidence, dict) else None))
            if attempt["translation_failed"]:
                attempt["warnings"].extend(row.get("warnings") or [])

            is_translation_only = (
                str(row.get("analyzer_model") or "") == "translation-only"
                or str(row.get("benchmark_mode") or "") == "translation"
            )
            if str(row.get("status") or "") != "translation_failed" and not is_translation_only:
                improver_model = analyzer_model
                explicit_provider = str(row.get("analyzer_provider") or analyzer_providers.get(improver_model) or "")
                provider = provider_for_model(improver_model, explicit_provider)
                bucket = improver_buckets.setdefault(improver_model, RoleBucket(improver_model, provider))
                improve_confidence = row.get("improve_confidence")
                improve_value = confidence_value(improve_confidence if isinstance(improve_confidence, dict) else None)
                improve_failed = confidence_failed(improve_confidence if isinstance(improve_confidence, dict) else None)
                improve_status = str(row.get("improve_status") or row.get("status") or "")
                row_status = str(row.get("status") or "")
                bucket.add_attempt(
                    run_dir=run_dir,
                    finished_at=finished_at,
                    case_id=case_id,
                    category=row.get("category"),
                    confidence=improve_value,
                    confidence_failed_value=improve_failed,
                    status=improve_status,
                    degraded=row_status == "degraded" or improve_status == "degraded",
                    pipeline_failed=improve_status not in {"ok", "degraded"} and row_status not in {"ok", "degraded"},
                    seconds=row.get("improve_seconds"),
                    warnings=confidence_warnings(improve_confidence if isinstance(improve_confidence, dict) else None)
                    + (list(row.get("warnings") or []) if row_status != "ok" or improve_status != "ok" else []),
                    related_model=translator_model,
                )

        for attempt in translation_attempts.values():
            model = str(attempt["model"])
            explicit_provider = translator_providers.get(model)
            provider = provider_for_model(model, explicit_provider)
            bucket = translation_buckets.setdefault(model, RoleBucket(model, provider))
            values = [float(value) for value in attempt["confidences"]]
            averaged = statistics.mean(values) if values else None
            bucket.add_attempt(
                run_dir=run_dir,
                finished_at=finished_at,
                case_id=str(attempt["case_id"]),
                category=attempt.get("category"),
                confidence=averaged,
                confidence_failed_value=bool(attempt["confidence_failed"]) and averaged is None,
                status="translation_failed" if attempt["translation_failed"] else "ok",
                degraded=bool(attempt["degraded"]),
                pipeline_failed=bool(attempt["translation_failed"]),
                seconds=attempt.get("seconds"),
                warnings=list(attempt["warnings"]),
                related_model=", ".join(sorted(attempt["related_models"])) if attempt["related_models"] else None,
            )

    def sort_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
        return sorted(
            rows,
            key=lambda item: (
                item["avg_confidence"] if item["avg_confidence"] is not None else -1,
                -int(item["confidence_failed_count"] or 0),
                -int(item["low_confidence_count"] or 0),
                int(item["attempts"] or 0),
            ),
            reverse=True,
        )

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "stress_dir": str(stress_dir),
        "scanned_runs": scanned_runs,
        "skipped_runs": skipped_runs,
        "translation_models": sort_rows([bucket.to_json() for bucket in translation_buckets.values()]),
        "improver_models": sort_rows([bucket.to_json() for bucket in improver_buckets.values()]),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stress-dir", default=str(ROOT / ".stress"))
    parser.add_argument("--pretty", action="store_true")
    args = parser.parse_args()

    payload = aggregate_stats(Path(args.stress_dir))
    print(json.dumps(payload, ensure_ascii=False, indent=2 if args.pretty else None))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

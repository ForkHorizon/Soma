from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field
from typing import Any

from rus_to_prompt_stats_core import (
    LOW_CONFIDENCE_THRESHOLD,
    mean_or_none,
    median_or_none,
    sorted_recent_runs,
)


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
        self._record_time_and_quality(finished_at, confidence, confidence_failed_value, degraded, pipeline_failed, seconds)
        self._record_warnings(warnings)
        self._record_run(run_dir, finished_at, confidence, confidence_failed_value, pipeline_failed)
        self._record_worst_case(
            run_dir, case_id, category, confidence, confidence_failed_value, status, degraded, pipeline_failed, warnings, related_model
        )

    def _record_time_and_quality(
        self,
        finished_at: str | None,
        confidence: float | None,
        confidence_failed_value: bool,
        degraded: bool,
        pipeline_failed: bool,
        seconds: float | None,
    ) -> None:
        if finished_at and (self.last_tested_at is None or finished_at > self.last_tested_at):
            self.last_tested_at = finished_at
        if confidence is not None:
            self.confidence_values.append(confidence)
            self.low_confidence_count += int(confidence < LOW_CONFIDENCE_THRESHOLD)
        elif confidence_failed_value:
            self.confidence_failed_count += 1
        self.pipeline_failed_count += int(pipeline_failed)
        self.degraded_count += int(degraded)
        if isinstance(seconds, (int, float)):
            self.seconds_values.append(float(seconds))

    def _record_warnings(self, warnings: list[str]) -> None:
        for warning in warnings[:5]:
            clean = str(warning or "").strip()
            if clean:
                self.warning_counts[clean] += 1

    def _record_run(
        self,
        run_dir: str,
        finished_at: str | None,
        confidence: float | None,
        confidence_failed_value: bool,
        pipeline_failed: bool,
    ) -> None:
        run_item = self.recent_runs.setdefault(run_dir, _empty_run(finished_at))
        run_item["attempts"] += 1
        if confidence is not None:
            run_item["confidence_values"].append(confidence)
            run_item["low_confidence_count"] += int(confidence < LOW_CONFIDENCE_THRESHOLD)
        if confidence_failed_value or pipeline_failed:
            run_item["failed_count"] += 1

    def _record_worst_case(
        self,
        run_dir: str,
        case_id: str,
        category: str | None,
        confidence: float | None,
        confidence_failed_value: bool,
        status: str,
        degraded: bool,
        pipeline_failed: bool,
        warnings: list[str],
        related_model: str | None,
    ) -> None:
        effective = confidence if confidence is not None else -1.0
        should_record = effective < LOW_CONFIDENCE_THRESHOLD or confidence_failed_value or pipeline_failed or degraded
        if not should_record:
            return
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
            "worst_cases": self._sorted_worst_cases(),
            "top_warnings": [{"warning": warning, "count": count} for warning, count in self.warning_counts.most_common(8)],
            "recent_runs": sorted_recent_runs(self.recent_runs),
        }

    def _sorted_worst_cases(self) -> list[dict[str, Any]]:
        return sorted(
            self.worst_cases,
            key=lambda item: (
                item.get("confidence") is not None,
                item.get("confidence") if item.get("confidence") is not None else -1.0,
            ),
        )[:10]


def _empty_run(finished_at: str | None) -> dict[str, Any]:
    return {
        "finished_at": finished_at,
        "attempts": 0,
        "confidence_values": [],
        "low_confidence_count": 0,
        "failed_count": 0,
    }

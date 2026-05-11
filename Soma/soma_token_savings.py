#!/usr/bin/env python3
"""Token savings model shared by runtime packet responses and benchmarks."""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from token_calculator import estimate_payload, estimate_tokens, estimate_tokens_for_chars, profile_for


BASELINE_PROMPT = (
    "Use the following raw project context, logs, configuration, and git changes "
    "to debug, review, and propose implementation changes. Do not assume missing files.\n\n"
)


def _round_pct(value: float | None) -> float | None:
    return None if value is None else round(value, 1)


def _safe_rel_path(path: str, project_root: str | None) -> str:
    if not project_root:
        return path
    try:
        return str(Path(path).resolve().relative_to(Path(project_root).resolve()))
    except Exception:
        return path


def _discovered_by_path(discovered: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {str(item.get("path")): item for item in discovered if isinstance(item, dict) and item.get("path")}


def _candidate_paths(preflight: dict[str, Any] | None, evidence_items: list[dict[str, Any]]) -> set[str]:
    paths: set[str] = set()
    for key in ("changed_paths", "error_paths", "candidate_paths", "explicit_paths", "log_candidates"):
        for path in (preflight or {}).get(key, []) or []:
            if isinstance(path, str) and path:
                paths.add(path)
    for item in evidence_items:
        path = item.get("path")
        if isinstance(path, str) and path:
            paths.add(path)
    return paths


def _baseline_result(
    *,
    name: str,
    characters: int,
    packet_tokens: int,
    model_profile: str,
    source: str,
    included_file_count: int = 0,
    caps: dict[str, Any] | None = None,
) -> dict[str, Any]:
    tokens = estimate_tokens_for_chars(characters, model_profile)
    saved = max(0, tokens - packet_tokens)
    return {
        "type": name,
        "source": source,
        "characters": max(0, characters),
        "tokens": tokens,
        "included_file_count": included_file_count,
        "saved_tokens": saved,
        "savings_pct": _round_pct(100 * saved / max(tokens, 1)),
        "caps": caps or {},
    }


def build_task_candidate_baseline(
    *,
    project_root: str | None,
    discovered: list[dict[str, Any]],
    preflight: dict[str, Any] | None,
    evidence_items: list[dict[str, Any]],
    git_status: str | None,
    git_diff_summary: dict[str, Any] | None,
    model_profile: str,
    packet_tokens: int,
    max_chars_per_file: int = 60000,
) -> dict[str, Any]:
    """Estimate the raw task context a user would likely paste without Soma.

    This intentionally uses scanner metadata and git omission sizes, not raw
    file bodies, so runtime logs never persist private source/log content.
    """
    by_path = _discovered_by_path(discovered)
    paths = _candidate_paths(preflight, evidence_items)
    if not paths and evidence_items:
        paths = {str(item.get("path")) for item in evidence_items if item.get("path")}

    total_chars = len(BASELINE_PROMPT) + len(git_status or "")
    included = 0
    for path in sorted(paths):
        item = by_path.get(path)
        size = int((item or {}).get("size", 0) or 0)
        if size <= 0:
            preview = next((ev.get("preview") for ev in evidence_items if ev.get("path") == path), "")
            size = len(preview or "")
        if size <= 0:
            continue
        included += 1
        rel = _safe_rel_path(path, project_root)
        total_chars += len(f"\n--- {rel} ---\n") + min(size, max_chars_per_file)

    diff_chars = int((git_diff_summary or {}).get("raw_diff_chars_omitted", 0) or 0)
    if diff_chars:
        total_chars += diff_chars

    return _baseline_result(
        name="task_candidates",
        characters=total_chars,
        packet_tokens=packet_tokens,
        model_profile=model_profile,
        source="scanner_sizes_git_omissions",
        included_file_count=included,
        caps={"max_chars_per_file": max_chars_per_file},
    )


def build_raw_repo_plus_diff_baseline(
    *,
    raw_repo_chars: int,
    raw_git_chars: int,
    included_file_count: int,
    packet_tokens: int,
    model_profile: str,
    caps: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return _baseline_result(
        name="raw_repo_plus_diff",
        characters=len(BASELINE_PROMPT) + max(0, raw_repo_chars) + max(0, raw_git_chars),
        packet_tokens=packet_tokens,
        model_profile=model_profile,
        source="opt_in_raw_repo_and_git_scan",
        included_file_count=included_file_count,
        caps=caps,
    )


def build_token_savings(
    *,
    packet: str,
    budget: str,
    budget_tokens: int,
    model_profile: str | None = None,
    task_candidate_baseline: dict[str, Any] | None = None,
    raw_repo_plus_diff_baseline: dict[str, Any] | None = None,
    status: str = "ok",
    warnings: list[str] | None = None,
) -> dict[str, Any]:
    profile = profile_for(model_profile)
    payload = estimate_payload(packet or "", profile.key)
    packet_tokens = int(payload["estimated_tokens"])
    all_warnings = list(warnings or [])
    baselines = {
        "task_candidates": task_candidate_baseline,
        "raw_repo_plus_diff": raw_repo_plus_diff_baseline,
    }

    primary = task_candidate_baseline or raw_repo_plus_diff_baseline
    if status != "ok" or not packet:
        all_warnings.append("No successful Soma packet was available, so savings were not calculated.")
        primary = None
        result_status = "unavailable"
    elif primary is None:
        all_warnings.append("No baseline was available for this packet.")
        result_status = "degraded"
    elif (primary.get("tokens") or 0) <= packet_tokens:
        all_warnings.append("Baseline is not larger than the Soma packet for this request.")
        result_status = "degraded"
    else:
        result_status = "ok"

    return {
        "status": result_status,
        "model_profile": profile.key,
        "label": profile.label,
        "estimator": payload["estimator"],
        "chars_per_token": payload["chars_per_token"],
        "exact_encoding": payload.get("exact_encoding"),
        "packet_tokens": packet_tokens,
        "budget": budget,
        "budget_tokens": budget_tokens,
        "budget_used_pct": _round_pct(100 * packet_tokens / max(budget_tokens, 1)),
        "baseline_type": primary.get("type") if primary else None,
        "baselines": baselines,
        "saved_tokens": primary.get("saved_tokens") if primary else None,
        "savings_pct": primary.get("savings_pct") if primary else None,
        "warnings": all_warnings,
    }


def unavailable_token_savings(
    *,
    reason: str,
    budget: str,
    budget_tokens: int,
    model_profile: str | None = None,
) -> dict[str, Any]:
    return build_token_savings(
        packet="",
        budget=budget,
        budget_tokens=budget_tokens,
        model_profile=model_profile,
        status="error",
        warnings=[reason],
    )


def summarize_for_cli(report: dict[str, Any]) -> str:
    return json.dumps(report, indent=2, sort_keys=True)

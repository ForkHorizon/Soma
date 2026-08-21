#!/usr/bin/env python3
"""Token savings model shared by runtime packet responses and benchmarks."""

from __future__ import annotations

import json
import hashlib
import subprocess
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


def _metric_result(
    *,
    metric: str,
    packet: str,
    budget: str,
    budget_tokens: int,
    model_profile: str,
    baseline: dict[str, Any] | None,
    status: str = "ok",
    warnings: list[str] | None = None,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    payload = estimate_payload(packet or "", model_profile)
    packet_tokens = int(payload["estimated_tokens"])
    all_warnings = list(warnings or [])
    if status != "ok" or not packet:
        baseline = None
        result_status = "unavailable"
        all_warnings.append("No successful Soma packet was available, so savings were not calculated.")
    elif baseline is None:
        result_status = "degraded"
        all_warnings.append("No baseline was available for this metric.")
    elif (baseline.get("tokens") or 0) <= packet_tokens:
        result_status = "degraded"
        all_warnings.append("Baseline is not larger than the Soma packet for this request.")
    else:
        result_status = "ok"

    result = {
        "metric": metric,
        "status": result_status,
        "model_profile": profile_for(model_profile).key,
        "estimator": payload["estimator"],
        "chars_per_token": payload["chars_per_token"],
        "exact_encoding": payload.get("exact_encoding"),
        "packet_tokens": packet_tokens,
        "budget": budget,
        "budget_tokens": budget_tokens,
        "budget_used_pct": _round_pct(100 * packet_tokens / max(budget_tokens, 1)),
        "baseline_type": baseline.get("type") if baseline else None,
        "baseline_tokens": baseline.get("tokens") if baseline else None,
        "saved_tokens": baseline.get("saved_tokens") if baseline else None,
        "savings_pct": baseline.get("savings_pct") if baseline else None,
        "warnings": all_warnings,
    }
    if extra:
        result.update(extra)
    return result


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


def build_estimated_context_reduction(
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
    baselines = {
        "task_candidates": task_candidate_baseline,
        "raw_repo_plus_diff": raw_repo_plus_diff_baseline,
    }
    primary = raw_repo_plus_diff_baseline or task_candidate_baseline
    result = _metric_result(
        metric="estimated_context_reduction",
        packet=packet,
        budget=budget,
        budget_tokens=budget_tokens,
        model_profile=profile.key,
        baseline=primary,
        status=status,
        warnings=warnings,
        extra={"baselines": baselines},
    )
    result["label"] = "Estimated context reduction"
    return result


def _hash_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", errors="replace")).hexdigest()


def _operation_item(
    *,
    source: str,
    kind: str,
    text: str,
    model_profile: str,
    path: str | None = None,
    command: str | None = None,
    truncated: bool = False,
) -> dict[str, Any]:
    return {
        "source": source,
        "kind": kind,
        "path": path,
        "command": command,
        "characters": len(text or ""),
        "tokens": estimate_tokens(text or "", model_profile),
        "sha256": _hash_text(text or ""),
        "truncated": truncated,
    }


def _git_diff_text(project_root: str | None) -> str:
    if not project_root:
        return ""
    try:
        return subprocess.run(
            ["git", "diff", "--no-ext-diff", "--no-color"],
            cwd=project_root,
            capture_output=True,
            text=True,
            check=False,
            timeout=15,
        ).stdout
    except Exception:
        return ""


def build_operation_savings(
    *,
    packet: str,
    project_root: str | None,
    git_status: str | None,
    evidence_items: list[dict[str, Any]],
    budget: str,
    budget_tokens: int,
    model_profile: str | None = None,
    max_chars_per_file: int = 60000,
) -> dict[str, Any]:
    """Estimate the concrete command/file outputs Soma avoided for this call.

    This reads command/file output only to count and hash it. It never returns
    raw source, raw logs, or raw diffs.
    """
    profile = profile_for(model_profile)
    operations: list[dict[str, Any]] = []
    if git_status:
        operations.append(
            _operation_item(
                source="git_status",
                kind="command",
                text=git_status,
                model_profile=profile.key,
                command="git status --short",
            )
        )

    diff = _git_diff_text(project_root)
    if diff:
        operations.append(
            _operation_item(
                source="git_diff",
                kind="command",
                text=diff,
                model_profile=profile.key,
                command="git diff --no-ext-diff --no-color",
            )
        )

    seen: set[str] = set()
    root_path = Path(project_root).resolve() if project_root else None
    for item in evidence_items:
        raw_path = item.get("path")
        if not raw_path or raw_path in seen:
            continue
        seen.add(raw_path)
        path = Path(raw_path)
        if not path.is_file():
            preview = item.get("preview") or ""
            if preview:
                operations.append(
                    _operation_item(
                        source="evidence_preview",
                        kind=str(item.get("kind") or "file"),
                        text=preview,
                        model_profile=profile.key,
                        path=_safe_rel_path(raw_path, project_root),
                    )
                )
            continue
        try:
            text = path.read_text(errors="replace")
        except Exception:
            continue
        truncated = len(text) > max_chars_per_file
        clipped = text[:max_chars_per_file]
        rel_path = _safe_rel_path(str(path), str(root_path) if root_path else project_root)
        operations.append(
            _operation_item(
                source="selected_evidence_file",
                kind=str(item.get("kind") or "file"),
                text=clipped,
                model_profile=profile.key,
                path=rel_path,
                truncated=truncated,
            )
        )

    baseline_tokens = sum(int(op.get("tokens") or 0) for op in operations)
    baseline_chars = sum(int(op.get("characters") or 0) for op in operations)
    packet_tokens = estimate_tokens(packet or "", profile.key)
    saved = max(0, baseline_tokens - packet_tokens)
    baseline = {
        "type": "operation_baseline",
        "source": "git_status_git_diff_selected_evidence_outputs",
        "characters": baseline_chars,
        "tokens": baseline_tokens,
        "included_file_count": sum(
            1 for op in operations if op.get("source") in {"selected_evidence_file", "evidence_preview"}
        ),
        "operation_count": len(operations),
        "saved_tokens": saved,
        "savings_pct": _round_pct(100 * saved / max(baseline_tokens, 1)),
        "caps": {"max_chars_per_file": max_chars_per_file},
    }
    result = _metric_result(
        metric="operation_savings",
        packet=packet,
        budget=budget,
        budget_tokens=budget_tokens,
        model_profile=profile.key,
        baseline=baseline if operations else None,
        extra={
            "label": "Operation savings",
            "operation_baseline_tokens": baseline_tokens,
            "operation_baseline_chars": baseline_chars,
            "soma_response_tokens": packet_tokens,
            "operations": operations,
        },
    )
    return result


def finalize_operation_savings_response_tokens(
    operation_savings: dict[str, Any] | None, soma_response_tokens: int
) -> dict[str, Any] | None:
    """Recompute operation savings against the full Soma tool response.

    Runtime callers build operation metadata before rendering the final JSON
    response. This finalizer updates saved tokens after the response size is
    known, which better matches what an agent actually receives from the tool.
    """
    if not isinstance(operation_savings, dict):
        return operation_savings
    updated = dict(operation_savings)
    baseline_tokens = updated.get("operation_baseline_tokens") or updated.get("baseline_tokens")
    updated["soma_response_tokens"] = max(0, int(soma_response_tokens or 0))
    if isinstance(baseline_tokens, (int, float)):
        saved = max(0, int(baseline_tokens) - updated["soma_response_tokens"])
        updated["saved_tokens"] = saved
        updated["savings_pct"] = _round_pct(100 * saved / max(int(baseline_tokens), 1))
        if int(baseline_tokens) <= updated["soma_response_tokens"] and updated.get("status") == "ok":
            updated["status"] = "degraded"
            warnings = list(updated.get("warnings") or [])
            warnings.append("Full Soma response was not smaller than the operation baseline.")
            updated["warnings"] = warnings
    return updated


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
    estimated_context_reduction: dict[str, Any] | None = None,
    operation_savings: dict[str, Any] | None = None,
    status: str = "ok",
    warnings: list[str] | None = None,
) -> dict[str, Any]:
    profile = profile_for(model_profile)
    payload = estimate_payload(packet or "", profile.key)
    all_warnings = list(warnings or [])
    if estimated_context_reduction is None:
        estimated_context_reduction = build_estimated_context_reduction(
            packet=packet,
            budget=budget,
            budget_tokens=budget_tokens,
            model_profile=profile.key,
            task_candidate_baseline=task_candidate_baseline,
            raw_repo_plus_diff_baseline=raw_repo_plus_diff_baseline,
            status=status,
            warnings=warnings,
        )
    primary_metric = operation_savings if operation_savings is not None else estimated_context_reduction
    if status != "ok" or not packet:
        result_status = "unavailable"
    else:
        result_status = (primary_metric or {}).get("status", "degraded")

    return {
        "status": result_status,
        "primary_metric": "operation_savings" if operation_savings is not None else "estimated_context_reduction",
        "model_profile": profile.key,
        "label": profile.label,
        "estimator": payload["estimator"],
        "chars_per_token": payload["chars_per_token"],
        "exact_encoding": payload.get("exact_encoding"),
        "packet_tokens": (primary_metric or {}).get("packet_tokens") or int(payload["estimated_tokens"]),
        "budget": budget,
        "budget_tokens": budget_tokens,
        "budget_used_pct": (primary_metric or {}).get("budget_used_pct"),
        "baseline_type": (primary_metric or {}).get("baseline_type"),
        "baselines": estimated_context_reduction.get("baselines")
        if isinstance(estimated_context_reduction, dict)
        else {
            "task_candidates": task_candidate_baseline,
            "raw_repo_plus_diff": raw_repo_plus_diff_baseline,
        },
        "saved_tokens": (primary_metric or {}).get("saved_tokens"),
        "savings_pct": (primary_metric or {}).get("savings_pct"),
        "estimated_context_reduction": estimated_context_reduction,
        "operation_savings": operation_savings,
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

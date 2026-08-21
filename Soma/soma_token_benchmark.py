#!/usr/bin/env python3
"""Benchmark Soma packet size against raw project context baselines."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from soma_token_savings import build_raw_repo_plus_diff_baseline
from token_calculator import estimate_payload, estimate_tokens, estimate_tokens_for_chars
from universal_fixtures import fixture_templates, prepare_fixture_repo


def _server_script() -> str:
    return str(Path(__file__).with_name("soma_mcp_server.py"))


def _read_raw_repo(
    root: Path,
    max_files: int = 120,
    max_chars_per_file: int = 60000,
    max_total_chars: int = 1_500_000,
) -> dict[str, Any]:
    total_chars = 0
    included_files = 0
    truncated = False
    for path in sorted(root.rglob("*")):
        if included_files >= max_files or total_chars >= max_total_chars:
            truncated = True
            break
        if not path.is_file() or ".git" in path.parts:
            continue
        try:
            text = path.read_text(errors="replace")
        except Exception:
            continue
        body_chars = min(len(text), max_chars_per_file, max(0, max_total_chars - total_chars))
        total_chars += len(f"--- {path.relative_to(root)} ---\n") + body_chars
        included_files += 1
        if len(text) > body_chars:
            truncated = True
    return {"characters": total_chars, "included_file_count": included_files, "truncated": truncated}


def _git_dump_chars(root: Path) -> int:
    status = subprocess.run(["git", "status", "--short"], cwd=root, capture_output=True, text=True, check=False).stdout
    diff = subprocess.run(
        ["git", "diff", "--no-ext-diff", "--no-color"], cwd=root, capture_output=True, text=True, check=False
    ).stdout
    return len(f"Git status:\n{status}\n\nGit diff:\n{diff}")


def _soma_packet(root: Path, python: str, budget: str, goal: str) -> dict[str, Any]:
    env = os.environ.copy()
    env["SOMA_PROJECT_ROOT"] = str(root)
    env["SOMA_GRAPHIFY_PROJECT_ONLY"] = "1"
    proc = subprocess.run(
        [
            python,
            _server_script(),
            "--project-root",
            str(root),
            "--run-tool",
            "soma_prepare_context",
            json.dumps({"goal": goal, "budget": budget, "depth": "deterministic"}),
        ],
        capture_output=True,
        text=True,
        env=env,
        timeout=90,
        check=False,
    )
    if proc.returncode != 0:
        return {"status": "error", "summary": proc.stderr[-500:], "packet": ""}
    try:
        return json.loads(proc.stdout)
    except Exception as exc:
        return {"status": "error", "summary": f"Invalid Soma JSON: {exc}", "packet": ""}


def _benchmark_project(
    root: Path,
    *,
    name: str,
    fixture_name: str | None = None,
    model_profile: str,
    python: str,
    budget: str,
    baseline: str,
    max_files: int,
    max_chars_per_file: int,
    max_total_chars: int,
) -> dict[str, Any]:
    goal = f"Debug and review recent changes in {name}; use source, git, config, and logs."
    soma = _soma_packet(root, python, budget, goal)
    packet = soma.get("packet") or ""
    packet_ok = soma.get("status") == "ok" and bool(packet.strip())
    packet_tokens = estimate_tokens(packet, model_profile) if packet_ok else None
    task_baseline = ((soma.get("token_savings") or {}).get("baselines") or {}).get("task_candidates")

    raw_baseline = None
    raw_repo_tokens = None
    raw_git_tokens = None
    raw_repo = {"characters": 0, "included_file_count": 0, "truncated": False}
    raw_git_chars = 0
    if baseline in {"both", "raw-repo-plus-diff"}:
        raw_repo = _read_raw_repo(
            root, max_files=max_files, max_chars_per_file=max_chars_per_file, max_total_chars=max_total_chars
        )
        raw_git_chars = _git_dump_chars(root)
        raw_repo_tokens = estimate_tokens_for_chars(raw_repo["characters"], model_profile)
        raw_git_tokens = estimate_tokens_for_chars(raw_git_chars, model_profile)
        if packet_ok and packet_tokens is not None:
            raw_baseline = build_raw_repo_plus_diff_baseline(
                raw_repo_chars=raw_repo["characters"],
                raw_git_chars=raw_git_chars,
                included_file_count=raw_repo["included_file_count"],
                packet_tokens=packet_tokens,
                model_profile=model_profile,
                caps={
                    "max_files": max_files,
                    "max_chars_per_file": max_chars_per_file,
                    "max_total_chars": max_total_chars,
                    "truncated": raw_repo["truncated"],
                },
            )

    primary = raw_baseline if baseline == "raw-repo-plus-diff" else task_baseline
    if baseline == "both":
        primary = raw_baseline or task_baseline
    status = "ok" if packet_ok and primary else "error"
    saved_tokens = primary.get("saved_tokens") if primary else None
    savings_pct = primary.get("savings_pct") if primary else None

    return {
        "fixture": fixture_name,
        "project": name,
        "project_root": str(root),
        "project_type": soma.get("project_type"),
        "status": status,
        "soma_status": soma.get("status"),
        "summary": soma.get("summary"),
        "budget": budget,
        "baseline": baseline,
        "model_profile": estimate_payload("", model_profile)["model_profile"],
        "raw_repo_tokens": raw_repo_tokens,
        "raw_git_tokens": raw_git_tokens,
        "baseline_tokens": primary.get("tokens") if primary else None,
        "task_candidate_tokens": task_baseline.get("tokens") if task_baseline else None,
        "raw_repo_plus_diff_tokens": raw_baseline.get("tokens") if raw_baseline else None,
        "soma_packet_tokens": packet_tokens,
        "estimated_tokens_reported": soma.get("estimated_tokens"),
        "saved_tokens": saved_tokens,
        "savings_pct": savings_pct,
        "token_savings": soma.get("token_savings"),
        "raw_repo_plus_diff_baseline": raw_baseline,
        "omitted": soma.get("omitted") or {},
        "graphify": "project_only",
    }


def _benchmark_fixture(
    template: Path, model_profile: str, python: str, budget: str, baseline: str, caps: dict[str, int]
) -> dict[str, Any]:
    tmp, root = prepare_fixture_repo(template)
    with tmp:
        return _benchmark_project(
            root,
            name=template.name,
            fixture_name=template.name,
            model_profile=model_profile,
            python=python,
            budget=budget,
            baseline=baseline,
            max_files=caps["max_files"],
            max_chars_per_file=caps["max_chars_per_file"],
            max_total_chars=caps["max_total_chars"],
        )


def _build_summary(results: list[dict[str, Any]], mode: str) -> dict[str, Any]:
    ok_results = [item for item in results if item.get("status") == "ok" and item.get("savings_pct") is not None]
    failed_results = [item for item in results if item.get("status") != "ok"]
    return {
        "mode": mode,
        "result_count": len(results),
        "valid_result_count": len(ok_results),
        "failed_result_count": len(failed_results),
        "fixture_count": len([item for item in results if item.get("fixture")]),
        "failed_fixture_count": len([item for item in failed_results if item.get("fixture")]),
        "avg_savings_pct": round(sum(item["savings_pct"] for item in ok_results) / max(len(ok_results), 1), 1)
        if ok_results
        else None,
        "total_baseline_tokens": sum(item.get("baseline_tokens") or 0 for item in ok_results),
        "total_soma_packet_tokens": sum(item.get("soma_packet_tokens") or 0 for item in ok_results),
        "total_saved_tokens": sum(item.get("saved_tokens") or 0 for item in ok_results),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Measure estimated Soma context reduction against raw baselines.")
    parser.add_argument("--fixtures", default=str(Path(__file__).parents[1] / "tests" / "fixtures" / "projects"))
    parser.add_argument("--project-root", default=None, help="Opt-in benchmark for a real selected project.")
    parser.add_argument("--model-profile", default="gpt-5.5")
    parser.add_argument("--budget", default="fast", choices=["micro", "fast", "balanced", "deep", "full"])
    parser.add_argument("--baseline", default="both", choices=["both", "task-candidates", "raw-repo-plus-diff"])
    parser.add_argument("--max-files", type=int, default=120)
    parser.add_argument("--max-chars-per-file", type=int, default=60000)
    parser.add_argument("--max-total-chars", type=int, default=1_500_000)
    parser.add_argument("--python", default=sys.executable)
    args = parser.parse_args()

    caps = {
        "max_files": args.max_files,
        "max_chars_per_file": args.max_chars_per_file,
        "max_total_chars": args.max_total_chars,
    }
    if args.project_root:
        root = Path(args.project_root).expanduser().resolve()
        results = [
            _benchmark_project(
                root,
                name=root.name,
                fixture_name=None,
                model_profile=args.model_profile,
                python=args.python,
                budget=args.budget,
                baseline=args.baseline,
                max_files=args.max_files,
                max_chars_per_file=args.max_chars_per_file,
                max_total_chars=args.max_total_chars,
            )
        ]
        mode = "project"
    else:
        results = [
            _benchmark_fixture(template, args.model_profile, args.python, args.budget, args.baseline, caps)
            for template in fixture_templates(args.fixtures)
        ]
        mode = "fixtures"

    summary = _build_summary(results, mode)
    status = "ok" if summary["valid_result_count"] == len(results) else "degraded"
    if summary["valid_result_count"] == 0:
        status = "error"
    report = {
        "status": status,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "model_profile": estimate_payload("", args.model_profile)["model_profile"],
        "budget": args.budget,
        "baseline": args.baseline,
        "caps": caps,
        "summary": summary,
        "results": results,
    }
    out_file = Path.home() / ".soma" / "token_stats.json"
    out_file.parent.mkdir(parents=True, exist_ok=True)
    rendered = json.dumps(report, indent=2, sort_keys=True)
    out_file.write_text(rendered)
    history_dir = out_file.parent / "token_stats"
    history_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    (history_dir / f"token_stats_{stamp}.json").write_text(rendered)
    print(rendered)
    return 1 if status == "error" else 0


if __name__ == "__main__":
    raise SystemExit(main())

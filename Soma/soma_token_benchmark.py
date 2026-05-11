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

from token_calculator import estimate_payload, estimate_tokens
from universal_fixtures import fixture_templates, prepare_fixture_repo


def _server_script() -> str:
    return str(Path(__file__).with_name("soma_mcp_server.py"))


def _read_raw_repo(root: Path, max_files: int = 120, max_chars_per_file: int = 60000) -> str:
    parts: list[str] = []
    for path in sorted(root.rglob("*")):
        if len(parts) >= max_files:
            break
        if not path.is_file() or ".git" in path.parts:
            continue
        try:
            text = path.read_text(errors="replace")[:max_chars_per_file]
        except Exception:
            continue
        parts.append(f"--- {path.relative_to(root)} ---\n{text}")
    return "\n\n".join(parts)


def _git_dump(root: Path) -> str:
    status = subprocess.run(["git", "status", "--short"], cwd=root, capture_output=True, text=True, check=False).stdout
    diff = subprocess.run(["git", "diff", "--no-ext-diff", "--no-color"], cwd=root, capture_output=True, text=True, check=False).stdout
    return f"Git status:\n{status}\n\nGit diff:\n{diff}"


def _soma_packet(root: Path, python: str, budget: str) -> dict[str, Any]:
    env = os.environ.copy()
    env["SOMA_PROJECT_ROOT"] = str(root)
    proc = subprocess.run(
        [
            python,
            _server_script(),
            "--project-root",
            str(root),
            "--run-tool",
            "soma_prepare_context",
            json.dumps({"goal": f"Debug and review recent changes in {root.name}", "budget": budget, "depth": "deterministic"}),
        ],
        capture_output=True,
        text=True,
        env=env,
        timeout=90,
        check=False,
    )
    if proc.returncode != 0:
        return {"status": "error", "summary": proc.stderr[-500:], "packet": ""}
    return json.loads(proc.stdout)


def _benchmark_fixture(template: Path, model_profile: str, python: str, budget: str) -> dict[str, Any]:
    tmp, root = prepare_fixture_repo(template)
    with tmp:
        raw_repo = _read_raw_repo(root)
        raw_git = _git_dump(root)
        soma = _soma_packet(root, python, budget)
        packet = soma.get("packet") or ""
        raw_repo_tokens = estimate_tokens(raw_repo, model_profile)
        raw_git_tokens = estimate_tokens(raw_git, model_profile)
        soma_tokens = estimate_tokens(packet, model_profile)
        baseline_prompt = (
            "Use the following raw repository snapshot, full logs, and git diff to debug, "
            "review, and propose implementation changes. Do not assume missing files.\n\n"
        )
        baseline_prompt_tokens = estimate_tokens(baseline_prompt, model_profile)
        baseline_tokens = baseline_prompt_tokens + raw_repo_tokens + raw_git_tokens
        saved = max(0, baseline_tokens - soma_tokens)
        return {
            "fixture": template.name,
            "project_type": soma.get("project_type"),
            "status": soma.get("status"),
            "budget": budget,
            "model_profile": estimate_payload("", model_profile)["model_profile"],
            "raw_repo_tokens": raw_repo_tokens,
            "raw_git_tokens": raw_git_tokens,
            "baseline_prompt_tokens": baseline_prompt_tokens,
            "baseline_tokens": baseline_tokens,
            "soma_packet_tokens": soma_tokens,
            "estimated_tokens_reported": soma.get("estimated_tokens"),
            "saved_tokens": saved,
            "savings_pct": round(100 * saved / max(baseline_tokens, 1), 1),
            "omitted": soma.get("omitted") or {},
        }


def main() -> int:
    parser = argparse.ArgumentParser(description="Measure Soma packet token savings against raw baselines.")
    parser.add_argument("--fixtures", default=str(Path(__file__).parents[1] / "tests" / "fixtures" / "projects"))
    parser.add_argument("--model-profile", default="gpt-5.5")
    parser.add_argument("--budget", default="fast", choices=["micro", "fast", "balanced", "deep", "full"])
    parser.add_argument("--python", default=sys.executable)
    args = parser.parse_args()

    results = [_benchmark_fixture(template, args.model_profile, args.python, args.budget) for template in fixture_templates(args.fixtures)]
    summary = {
        "fixture_count": len(results),
        "avg_savings_pct": round(sum(item["savings_pct"] for item in results) / max(len(results), 1), 1),
        "total_baseline_tokens": sum(item["baseline_tokens"] for item in results),
        "total_soma_packet_tokens": sum(item["soma_packet_tokens"] for item in results),
        "total_saved_tokens": sum(item["saved_tokens"] for item in results),
    }
    report = {
        "status": "ok",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "model_profile": estimate_payload("", args.model_profile)["model_profile"],
        "budget": args.budget,
        "summary": summary,
        "results": results,
    }
    out_file = Path.home() / ".soma" / "token_stats.json"
    out_file.parent.mkdir(parents=True, exist_ok=True)
    out_file.write_text(json.dumps(report, indent=2, sort_keys=True))
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

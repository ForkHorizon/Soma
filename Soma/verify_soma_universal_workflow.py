#!/usr/bin/env python3
"""Verify Soma core evidence workflow across non-Unity project fixtures."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from token_calculator import estimate_tokens
from universal_fixtures import fixture_templates, prepare_fixture_repo

EXPECTED_CORE_TOOLS = [
    "soma_get_map",
    "soma_prepare_context",
    "soma_ask",
    "soma_code_context",
    "soma_debug",
    "soma_review",
    "soma_delta",
    "soma_remember",
]


def _server_script() -> str:
    return str(Path(__file__).with_name("soma_mcp_server.py"))


def _log_file_path() -> str:
    return str(Path.home() / ".soma" / "logs" / f"soma_{datetime.now(timezone.utc).strftime('%Y%m%d')}.jsonl")


def _save_report(report: dict[str, Any]) -> None:
    out_dir = Path.home() / ".soma" / "acceptance" / "universal"
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    report_path = out_dir / f"universal_{stamp}.json"
    latest = out_dir / "latest.json"
    report["report_path"] = str(report_path)
    report["latest_report"] = str(latest)
    text = json.dumps(report, indent=2, sort_keys=True)
    report_path.write_text(text)
    latest.write_text(text)


def _call_tool(tool: str, params: dict[str, Any], project_root: Path, python: str) -> dict[str, Any]:
    env = os.environ.copy()
    env["SOMA_PROJECT_ROOT"] = str(project_root)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    proc = subprocess.run(
        [python, _server_script(), "--project-root", str(project_root), "--run-tool", tool, json.dumps(params)],
        capture_output=True,
        text=True,
        env=env,
        timeout=90,
        check=False,
    )
    if proc.returncode != 0:
        return {"status": "error", "summary": proc.stderr[-500:] or proc.stdout[-500:], "returncode": proc.returncode}
    try:
        payload = json.loads(proc.stdout)
    except Exception:
        payload = {"status": "invalid_json", "summary": proc.stdout[:500]}
    payload["_stdout_bytes"] = len(proc.stdout)
    return payload


def _ollama_health() -> dict[str, Any]:
    ranker = os.environ.get("SOMA_RANKER_MODEL", "gemma4:e4b")
    analyst = os.environ.get("SOMA_ANALYST_MODEL", "qwen3-coder:30b-a3b-q4_K_M")
    payload = {
        "model": ranker,
        "think": False,
        "messages": [
            {"role": "system", "content": 'Return JSON only: {"ordered_ids":[0]}'},
            {"role": "user", "content": '{"candidates":[{"id":0,"path":"main.py"}]}'},
        ],
        "stream": False,
        "format": "json",
        "options": {"num_ctx": 512, "num_predict": 48, "temperature": 0.1},
    }
    try:
        req = urllib.request.Request(
            "http://127.0.0.1:11434/api/chat",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as response:
            decoded = json.loads(response.read().decode())
        content = decoded.get("message", {}).get("content", "")
        parsed = json.loads(content) if isinstance(content, str) else {}
        ok = isinstance(parsed.get("ordered_ids"), list)
        return {"status": "ok" if ok else "degraded", "ranker_model": ranker, "analyst_model": analyst, "json_mode": ok}
    except Exception as exc:
        return {"status": "offline", "ranker_model": ranker, "analyst_model": analyst, "error": str(exc)[:240]}


def _fixture_goal(name: str) -> str:
    return f"Debug recent changed behavior in {name}; check source, git diff, config, and logs."


def _verify_fixture(template: Path, budget: str, python: str) -> dict[str, Any]:
    tmp, root = prepare_fixture_repo(template)
    with tmp:
        result: dict[str, Any] = {"fixture": template.name, "project_root": str(root), "calls": {}, "issues": []}
        get_map = _call_tool("soma_get_map", {}, root, python)
        result["calls"]["soma_get_map"] = _compact_call(get_map)
        project_type = ((get_map.get("map") or {}).get("project") or {}).get("type")
        result["project_type"] = project_type

        prepare = _call_tool(
            "soma_prepare_context",
            {"goal": _fixture_goal(template.name), "budget": budget, "depth": "deterministic"},
            root,
            python,
        )
        result["calls"]["soma_prepare_context"] = _compact_call(prepare)
        result["estimated_tokens"] = prepare.get("estimated_tokens")
        result["budget"] = budget
        result["evidence_count"] = len(prepare.get("evidence") or [])
        result["omitted"] = prepare.get("omitted") or {}
        packet = prepare.get("packet") or ""

        for name, payload in (("soma_get_map", get_map), ("soma_prepare_context", prepare)):
            if payload.get("status") not in {"ok", "degraded"}:
                result["issues"].append(f"{name}_{payload.get('status')}")
        if not packet:
            result["issues"].append("empty_packet")
        if prepare.get("estimated_tokens", 0) > 2500 and budget == "fast":
            result["issues"].append("budget_exceeded")
        if not prepare.get("evidence"):
            result["issues"].append("missing_evidence")
        if "diff --git" in packet:
            result["issues"].append("raw_diff_leaked")
        if ".DS_Store" in packet or "__pycache__" in packet:
            result["issues"].append("noise_leaked")

        code_context = _call_tool("soma_code_context", {"query": _fixture_goal(template.name)}, root, python)
        result["calls"]["soma_code_context"] = _compact_call(code_context)
        delta = _call_tool("soma_delta", {}, root, python)
        result["calls"]["soma_delta"] = _compact_call(delta)

        result["status"] = "ok" if not result["issues"] else "degraded"
        return result


def _verify_depths(templates: list[Path], budget: str, python: str, local_ai_status: dict[str, Any]) -> dict[str, Any]:
    checks: dict[str, Any] = {
        "deterministic": {"status": "ok", "scope": "all_fixtures"},
        "ranked": {"status": "skipped", "reason": "no_fixture"},
        "analyst": {"status": "skipped", "reason": "no_fixture"},
    }
    if not templates:
        checks["deterministic"] = {"status": "degraded", "reason": "no_fixtures"}
        return checks
    if local_ai_status.get("status") != "ok":
        for depth in ("ranked", "analyst"):
            checks[depth] = {
                "status": "degraded",
                "reason": "local_ai_offline",
                "model_status": local_ai_status.get("status"),
            }
        return checks
    template = templates[0]
    tmp, root = prepare_fixture_repo(template)
    with tmp:
        for depth in ("ranked", "analyst"):
            payload = _call_tool(
                "soma_prepare_context",
                {"goal": _fixture_goal(template.name), "budget": budget, "depth": depth},
                root,
                python,
            )
            stages = payload.get("analysis_stages") or []
            checks[depth] = {
                "status": payload.get("status") if payload.get("status") in {"ok", "degraded"} else "degraded",
                "fixture": template.name,
                "estimated_tokens": payload.get("estimated_tokens"),
                "evidence_count": len(payload.get("evidence") or []),
                "analysis_stage_statuses": {
                    stage.get("stage"): stage.get("status") for stage in stages if isinstance(stage, dict)
                },
            }
    return checks


def _compact_call(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "status": payload.get("status"),
        "summary": str(payload.get("summary", ""))[:240],
        "estimated_tokens": payload.get("estimated_tokens"),
        "evidence_count": len(payload.get("evidence") or []),
        "bytes": payload.get("_stdout_bytes"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify universal Soma evidence workflow without Unity/Nexus.")
    parser.add_argument("--fixtures", default=str(Path(__file__).parents[1] / "tests" / "fixtures" / "projects"))
    parser.add_argument("--budget", default="fast", choices=["micro", "fast", "balanced", "deep", "full"])
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--strict-exit", action="store_true")
    args = parser.parse_args()

    templates = fixture_templates(args.fixtures)
    results = [_verify_fixture(template, args.budget, args.python) for template in templates]
    local_ai_status = _ollama_health()
    depth_checks = _verify_depths(templates, args.budget, args.python, local_ai_status)
    report = {
        "status": "ok"
        if all(item["status"] == "ok" for item in results) and depth_checks["deterministic"]["status"] == "ok"
        else "degraded",
        "core_status": "ok"
        if all(item["calls"].get("soma_prepare_context", {}).get("status") == "ok" for item in results)
        else "degraded",
        "plugin_status": {"unity_nexus": "skipped"},
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "fixtures_dir": str(Path(args.fixtures).resolve()),
        "budget": args.budget,
        "log_path": _log_file_path(),
        "local_ai_status": local_ai_status,
        "depth_checks": depth_checks,
        "results": results,
    }
    _save_report(report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 1 if args.strict_exit and report["status"] != "ok" else 0


if __name__ == "__main__":
    raise SystemExit(main())

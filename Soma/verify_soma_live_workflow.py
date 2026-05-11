#!/usr/bin/env python3
"""Verify Soma MCP through a real stdio MCP client session."""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


EXPECTED_TOOLS = [
    "soma_prepare_context",
    "soma_get_map",
    "soma_ask",
    "soma_code_context",
    "soma_scene",
    "soma_inspect",
    "soma_debug",
    "soma_review",
    "soma_delta",
    "soma_apply",
    "soma_execute",
    "soma_remember",
]


DEFAULT_APPLY_PATH = "Assets/NexusUnity/Editor/Tests/SomaApplySmokeTest.cs"
DEFAULT_APPLY_CONTENT = (
    "namespace UnityMCP.Editor.Tests {\n"
    "    internal static class SomaApplySmokeTest {\n"
    "        internal const string Marker = \"SomaApplySmokeTest\";\n"
    "    }\n"
    "}\n"
)


def _server_script() -> str:
    return str(Path(__file__).with_name("soma_mcp_server.py"))


def _log_file_path() -> str:
    date_str = datetime.now(timezone.utc).strftime("%Y%m%d")
    return str(Path.home() / ".soma" / "logs" / f"soma_{date_str}.jsonl")


def _paths_match(left: str | None, right: str | None) -> bool:
    if not left or not right:
        return True
    try:
        return Path(left).expanduser().resolve() == Path(right).expanduser().resolve()
    except Exception:
        return os.path.abspath(left) == os.path.abspath(right)


def _save_acceptance_report(report: dict[str, Any]) -> dict[str, str]:
    out_dir = Path.home() / ".soma" / "acceptance"
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    report_path = out_dir / f"e2e_{stamp}.json"
    latest_path = out_dir / "latest.json"
    report["acceptance_report"] = str(report_path)
    report["latest_report"] = str(latest_path)
    text = json.dumps(report, indent=2, sort_keys=True)
    report_path.write_text(text)
    latest_path.write_text(text)
    return {"report_path": str(report_path), "latest_path": str(latest_path)}


def _content_text(result: Any) -> str:
    content = getattr(result, "content", [])
    if not content:
        return ""
    first = content[0]
    return getattr(first, "text", str(first))


def _compact_payload(text: str) -> dict[str, Any]:
    try:
        payload = json.loads(text)
    except Exception:
        return {"status": "invalid_json", "summary": text[:240], "bytes": len(text)}
    return {
        "status": payload.get("status"),
        "summary": payload.get("summary", "")[:240],
        "bytes": len(text),
        "has_evidence": bool(payload.get("evidence")),
        "has_omitted": "omitted" in payload,
        "next_calls": payload.get("next_calls", [])[:3],
    }


def _json_payload(result: Any) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    text = _content_text(result)
    try:
        payload = json.loads(text)
    except Exception:
        return None, {"status": "invalid_json", "summary": text[:240], "bytes": len(text)}
    return payload, _compact_payload(text)


def _find_instance_id(value: Any) -> int | None:
    if isinstance(value, dict):
        for key in ("instance_id", "instanceId", "instanceID", "id"):
            candidate = value.get(key)
            if isinstance(candidate, int):
                return candidate
            if isinstance(candidate, str) and candidate.isdigit():
                return int(candidate)
        for nested in value.values():
            found = _find_instance_id(nested)
            if found is not None:
                return found
    elif isinstance(value, list):
        for nested in value:
            found = _find_instance_id(nested)
            if found is not None:
                return found
    return None


async def _call_compact(session: Any, name: str, params: dict[str, Any]) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    start = time.monotonic()
    payload, compact = _json_payload(await session.call_tool(name, params))
    compact["duration_ms"] = round((time.monotonic() - start) * 1000, 1)
    return payload, compact


async def verify_session(session: Any, args: argparse.Namespace) -> dict[str, Any]:
    report: dict[str, Any] = {
        "status": "ok",
        "project_root": args.project_root,
        "tools": {},
        "calls": {},
        "issues": [],
        "log_file": _log_file_path(),
        "core_status": "ok",
        "plugin_status": {"unity_nexus": "pending" if args.live_unity else "skipped"},
    }

    tools_result = await session.list_tools()
    tool_names = [tool.name for tool in tools_result.tools]
    report["tools"] = {
        "count": len(tool_names),
        "names": tool_names,
        "expected_count": len(EXPECTED_TOOLS),
        "missing": [name for name in EXPECTED_TOOLS if name not in tool_names],
        "unexpected": [name for name in tool_names if name not in EXPECTED_TOOLS],
        "unity_exposed": [name for name in tool_names if name.startswith("unity_")],
    }

    if report["tools"]["count"] != len(EXPECTED_TOOLS):
        report["issues"].append("tool_count_mismatch")
    if report["tools"]["missing"] or report["tools"]["unexpected"]:
        report["issues"].append("tool_catalog_mismatch")
    if report["tools"]["unity_exposed"]:
        report["issues"].append("unity_tools_exposed")

    payload, compact = await _call_compact(session, "soma_get_map", {})
    report["calls"]["soma_get_map"] = compact
    if payload and isinstance(payload.get("map"), dict):
        graph = payload["map"].get("graph") or {}
        nexus = payload["map"].get("nexus") or {}
        report["graph"] = {
            "available": graph.get("available"),
            "project_graph_available": graph.get("project_graph_available"),
            "stale": graph.get("stale"),
        }
        report["nexus"] = {
            "connected": nexus.get("connected"),
            "port": nexus.get("port"),
            "project_path": nexus.get("project_path") or nexus.get("projectPath"),
            "session_id": nexus.get("session_id"),
        }
        if args.live_unity and not nexus.get("connected"):
            report["issues"].append("nexus_offline")
        nexus_project = report["nexus"].get("project_path")
        if args.live_unity and nexus.get("connected") and not _paths_match(args.project_root, nexus_project):
            report["issues"].append("wrong_project")
            report["wrong_project"] = {"expected": args.project_root, "actual": nexus_project}
    if compact["status"] == "invalid_json":
        report["issues"].append("soma_get_map_invalid_json")

    _, compact = await _call_compact(
        session,
        "soma_prepare_context",
        {"goal": args.goal, "budget": "fast", "depth": "deterministic"},
    )
    report["calls"]["soma_prepare_context"] = compact
    if compact["status"] == "invalid_json":
        report["issues"].append("soma_prepare_context_invalid_json")

    if args.live_unity:
        scene_payload, compact = await _call_compact(session, "soma_scene", {})
        report["calls"]["soma_scene"] = compact
        if compact["status"] == "invalid_json":
            report["issues"].append("soma_scene_invalid_json")
        if compact["status"] != "ok":
            report["issues"].append("live_scene_failed")

        inspect_id = args.inspect_id
        if inspect_id is None and scene_payload:
            inspect_id = _find_instance_id(scene_payload.get("scene", scene_payload))
        if inspect_id is None:
            report["calls"]["soma_inspect"] = {"status": "skipped", "summary": "No inspectable instance id found in scene."}
            report["issues"].append("inspect_id_not_found")
        else:
            _, compact = await _call_compact(session, "soma_inspect", {"instance_id": inspect_id})
            report["calls"]["soma_inspect"] = compact | {"instance_id": inspect_id}
            if compact["status"] != "ok":
                report["issues"].append("live_inspect_failed")
    else:
        report["calls"]["soma_scene"] = {"status": "skipped", "summary": "Pass --live-unity when Unity plugin should be verified."}
        report["calls"]["soma_inspect"] = {"status": "skipped", "summary": "Pass --live-unity when Nexus is online."}

    _, compact = await _call_compact(session, "soma_delta", {})
    report["calls"]["soma_delta"] = compact
    if compact["status"] == "invalid_json":
        report["issues"].append("soma_delta_invalid_json")

    wrong_project = "wrong_project" in report["issues"]
    if args.run_apply and wrong_project:
        report["calls"]["soma_apply"] = {
            "status": "skipped",
            "summary": "Skipped live apply because Nexus is connected to a different project.",
            "path": args.apply_path,
        }
        if args.cleanup_apply:
            report["calls"]["cleanup_apply"] = {
                "status": "skipped",
                "summary": "Skipped cleanup because apply was not run.",
                "path": args.apply_path,
            }
    elif args.run_apply:
        _, compact = await _call_compact(
            session,
            "soma_apply",
            {"files": [{"path": args.apply_path, "content": args.apply_content}]},
        )
        report["calls"]["soma_apply"] = compact | {"path": args.apply_path}
        if args.live_unity and compact["status"] != "ok":
            report["issues"].append("live_apply_failed")

        if args.cleanup_apply:
            _, cleanup = await _call_compact(
                session,
                "soma_execute",
                {"requests": [{"method": "delete_asset", "params": {"path": args.apply_path}}]},
            )
            cleanup["path"] = args.apply_path
            report["calls"]["cleanup_apply"] = cleanup
            if cleanup["status"] != "ok":
                report["issues"].append("cleanup_apply_failed")
                report["leftover_path"] = args.apply_path
    else:
        report["calls"]["soma_apply"] = {"status": "skipped", "summary": "Pass --run-apply for live Unity compile check."}

    if report["issues"]:
        report["status"] = "degraded"
    report["core_status"] = "ok" if not any(issue.endswith("invalid_json") or issue.startswith("tool_") for issue in report["issues"]) else "degraded"
    if args.live_unity:
        plugin_issues = {"nexus_offline", "live_scene_failed", "inspect_id_not_found", "live_inspect_failed", "wrong_project", "live_apply_failed", "cleanup_apply_failed"}
        report["plugin_status"]["unity_nexus"] = "degraded" if any(issue in plugin_issues for issue in report["issues"]) else "ok"
    return report


async def run(args: argparse.Namespace) -> dict[str, Any]:
    env = os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    if args.project_root:
        env["SOMA_PROJECT_ROOT"] = args.project_root

    server = StdioServerParameters(
        command=args.python,
        args=[_server_script(), "--project-root", args.project_root] if args.project_root else [_server_script()],
        env=env,
    )

    with open(os.devnull, "w") as errlog:
        async with stdio_client(server, errlog=errlog) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                return await verify_session(session, args)


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify Soma MCP live workflow over stdio.")
    parser.add_argument("--project-root", default=os.environ.get("SOMA_PROJECT_ROOT", ""))
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--goal", default="Prepare a compact debug packet for the Unity MCP gateway.")
    parser.add_argument("--inspect-id", type=int, default=None)
    parser.add_argument("--live-unity", action="store_true")
    parser.add_argument("--run-apply", action="store_true")
    parser.add_argument("--cleanup-apply", action="store_true")
    parser.add_argument("--strict-exit", action="store_true")
    parser.add_argument("--apply-path", default=DEFAULT_APPLY_PATH)
    parser.add_argument("--apply-content", default=DEFAULT_APPLY_CONTENT)
    args = parser.parse_args()

    report = asyncio.run(run(args))
    _save_acceptance_report(report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 1 if args.strict_exit and report["status"] != "ok" else 0


if __name__ == "__main__":
    raise SystemExit(main())

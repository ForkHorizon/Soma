#!/usr/bin/env python3
"""Verify Soma MCP through a real stdio MCP client session."""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
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
    return _json_payload(await session.call_tool(name, params))


async def verify_session(session: Any, args: argparse.Namespace) -> dict[str, Any]:
    report: dict[str, Any] = {
        "status": "ok",
        "project_root": args.project_root,
        "tools": {},
        "calls": {},
        "issues": [],
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
            "session_id": nexus.get("session_id"),
        }
        if args.live_unity and not nexus.get("connected"):
            report["issues"].append("nexus_offline")
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

    scene_payload, compact = await _call_compact(session, "soma_scene", {})
    report["calls"]["soma_scene"] = compact
    if compact["status"] == "invalid_json":
        report["issues"].append("soma_scene_invalid_json")
    if args.live_unity and compact["status"] != "ok":
        report["issues"].append("live_scene_failed")

    inspect_id = args.inspect_id
    if inspect_id is None and scene_payload:
        inspect_id = _find_instance_id(scene_payload.get("scene", scene_payload))
    if args.live_unity:
        if inspect_id is None:
            report["calls"]["soma_inspect"] = {"status": "skipped", "summary": "No inspectable instance id found in scene."}
            report["issues"].append("inspect_id_not_found")
        else:
            _, compact = await _call_compact(session, "soma_inspect", {"instance_id": inspect_id})
            report["calls"]["soma_inspect"] = compact | {"instance_id": inspect_id}
            if compact["status"] != "ok":
                report["issues"].append("live_inspect_failed")
    else:
        report["calls"]["soma_inspect"] = {"status": "skipped", "summary": "Pass --live-unity when Nexus is online."}

    _, compact = await _call_compact(session, "soma_delta", {})
    report["calls"]["soma_delta"] = compact
    if compact["status"] == "invalid_json":
        report["issues"].append("soma_delta_invalid_json")

    if args.run_apply:
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
    print(json.dumps(report, indent=2, sort_keys=True))
    return 1 if args.strict_exit and report["status"] != "ok" else 0


if __name__ == "__main__":
    raise SystemExit(main())

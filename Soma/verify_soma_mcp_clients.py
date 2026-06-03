#!/usr/bin/env python3
"""Verify Soma client configs and run a guarded live MCP smoke.

The report is metadata-only: no raw packet, source, transcript, or tool body is
persisted. Tool outputs are reduced to status, summary, size, and hash.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import select
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from soma_import_bootstrap import install_soma_gateway_namespace

install_soma_gateway_namespace(Path(__file__).parent)

from gateway.client_config import verify_codex_config, verify_gemini_config, verify_hermes_config
from gateway.status import build_status_payload
from gateway.tool_registry import TOOL_ORDER, tool_schema
from soma_logger import log_mcp_event
from scout_pipeline import normalize_path

REPORT_DIR = Path.home() / ".soma" / "mcp_smoke"
PLUGIN_TOOLS = {"soma_scene", "soma_inspect", "soma_apply", "soma_execute"}
CORE_CALLS: dict[str, dict[str, Any]] = {
    "soma_prepare_context": {
        "goal": "MCP smoke: identify project structure and current git state.",
        "budget": "micro",
        "depth": "deterministic",
    },
    "soma_get_map": {},
    "soma_ask": {"question": "MCP smoke: what project is selected?"},
    "soma_code_context": {"query": "MCP smoke project entrypoint"},
    "soma_delta": {},
    "soma_remember": {"action": "list"},
}
SCHEMA_ONLY_CORE = {
    "soma_debug": "ranked local-AI path; schema checked in default smoke",
    "soma_review": "ranked local-AI path; schema checked in default smoke",
}


def _now() -> str:
    return datetime.now(tz=timezone.utc).isoformat()


def _sha(text: str) -> str:
    return "sha256:" + hashlib.sha256(text.encode("utf-8", errors="replace")).hexdigest()


def _short_summary(result: dict[str, Any]) -> str | None:
    summary = result.get("summary")
    if summary is None:
        return None
    return str(summary)[:300]


def _project_matches(selected: str | None, nexus_project: str | None) -> bool:
    if not selected or not nexus_project:
        return False
    return normalize_path(selected) == normalize_path(nexus_project)


class DaemonClient:
    def __init__(self, python: str, project_root: str, timeout: float):
        self.python = python
        self.project_root = project_root
        self.timeout = timeout
        self.proc: subprocess.Popen[str] | None = None
        self.next_id = 1

    def __enter__(self) -> "DaemonClient":
        script = Path(__file__).with_name("soma_mcp_server.py")
        env = dict(os.environ)
        env["SOMA_PROJECT_ROOT"] = self.project_root
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        self.proc = subprocess.Popen(
            [self.python, str(script), "--project-root", self.project_root, "--daemon"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            bufsize=1,
        )
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        if not self.proc:
            return
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        for handle in (self.proc.stdout, self.proc.stderr):
            try:
                if handle:
                    handle.close()
            except Exception:
                pass

    def call(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        if not self.proc or not self.proc.stdin or not self.proc.stdout:
            raise RuntimeError("daemon not started")
        req_id = self.next_id
        self.next_id += 1
        request = {"jsonrpc": "2.0", "id": req_id, "method": method, "params": params or {}}
        self.proc.stdin.write(json.dumps(request) + "\n")
        self.proc.stdin.flush()
        ready, _, _ = select.select([self.proc.stdout], [], [], self.timeout)
        if not ready:
            raise TimeoutError(f"MCP daemon timed out on {method}")
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError(f"MCP daemon exited before {method} response")
        response = json.loads(line)
        if response.get("error"):
            raise RuntimeError(response["error"].get("message", str(response["error"])))
        return response.get("result") or {}


def _safe_tool_record(tool: str, status: str, started: float, result: dict[str, Any] | None = None, reason: str | None = None) -> dict[str, Any]:
    rendered = json.dumps(result or {}, default=str, sort_keys=True)
    record = {
        "tool": tool,
        "status": status,
        "duration_ms": round((time.monotonic() - started) * 1000, 1),
        "output_chars": len(rendered),
        "output_hash": _sha(rendered),
    }
    if result:
        record["result_status"] = result.get("status")
        if _short_summary(result):
            record["summary"] = _short_summary(result)
    if reason:
        record["reason"] = reason
    return record


def _log_tool_record(record: dict[str, Any], project_root: str) -> None:
    log_mcp_event(
        event="mcp_tool_smoke",
        tool=record["tool"],
        status=record["status"],
        duration_ms=record.get("duration_ms"),
        project_root=project_root,
        extra={
            "result_status": record.get("result_status"),
            "reason": record.get("reason"),
            "output_chars": record.get("output_chars"),
            "output_hash": record.get("output_hash"),
        },
    )


def _client_config_statuses(args: argparse.Namespace, project_root: str) -> dict[str, Any]:
    requested = {item.strip() for item in (args.clients or "codex,gemini").split(",") if item.strip()}
    statuses: dict[str, Any] = {}
    if "codex" in requested:
        statuses["codex"] = verify_codex_config(args.codex_config_path, project_root)
    if "gemini" in requested:
        statuses["gemini"] = verify_gemini_config(args.gemini_config_path, project_root)
    if "hermes" in requested:
        statuses["hermes"] = verify_hermes_config(args.hermes_config_path, project_root)
    return statuses


def run_smoke(args: argparse.Namespace) -> dict[str, Any]:
    project_root = normalize_path(args.project_root or os.environ.get("SOMA_PROJECT_ROOT") or os.getcwd())
    started = time.monotonic()
    generated_at = _now()
    config_statuses = _client_config_statuses(args, project_root)
    server_status = build_status_payload(project_root)
    nexus = server_status.get("nexus") or {}
    plugin_ready = bool(nexus.get("connected")) and _project_matches(project_root, nexus.get("project_path"))

    initialize: dict[str, Any] = {"status": "not_run"}
    tools_list: dict[str, Any] = {"status": "not_run"}
    tool_results: list[dict[str, Any]] = []
    issues: list[str] = []

    try:
        with DaemonClient(args.python, project_root, args.timeout) as daemon:
            init_started = time.monotonic()
            init_result = daemon.call("initialize", {})
            initialize = _safe_tool_record("initialize", "ok", init_started, init_result)

            list_started = time.monotonic()
            list_result = daemon.call("tools/list", {})
            tools = list_result.get("tools") if isinstance(list_result.get("tools"), list) else []
            tools_list = _safe_tool_record("tools/list", "ok", list_started, {"status": "ok", "tool_count": len(tools)})
            tools_list["tool_count"] = len(tools)
            tools_list["tool_names"] = [tool.get("name") for tool in tools if isinstance(tool, dict)]

            if len(tools) != len(TOOL_ORDER):
                issues.append(f"tool_count={len(tools)}")
            for name in TOOL_ORDER:
                schema = tool_schema(name)
                if not schema.get("properties") and name not in {"soma_get_map", "soma_scene", "soma_delta"}:
                    issues.append(f"schema_missing:{name}")

            for tool in TOOL_ORDER:
                call_started = time.monotonic()
                if tool in CORE_CALLS:
                    try:
                        result = daemon.call("tools/call", {"name": tool, "arguments": CORE_CALLS[tool]})
                        status = result.get("status", "ok") if isinstance(result, dict) else "ok"
                        smoke_status = "ok" if status in {"ok", "degraded"} else "error"
                        record = _safe_tool_record(tool, smoke_status, call_started, result)
                    except Exception as exc:
                        record = _safe_tool_record(tool, "error", call_started, {"status": "error", "summary": str(exc)})
                elif tool in SCHEMA_ONLY_CORE:
                    record = _safe_tool_record(tool, "skipped", call_started, reason=SCHEMA_ONLY_CORE[tool])
                elif tool in PLUGIN_TOOLS:
                    reason = "plugin_guarded"
                    if not plugin_ready:
                        reason = "plugin_guarded: Nexus offline or project mismatch"
                    record = _safe_tool_record(tool, "skipped", call_started, reason=reason)
                else:
                    record = _safe_tool_record(tool, "skipped", call_started, reason="no default smoke arguments")
                tool_results.append(record)
                _log_tool_record(record, project_root)
    except Exception as exc:
        issues.append(f"daemon_error:{exc}")
        initialize = {"tool": "initialize", "status": "error", "summary": str(exc)}

    _append_missing_plugin_records(tool_results, plugin_ready, project_root)
    failed_tools = [item["tool"] for item in tool_results if item.get("status") == "error"]
    config_degraded = [client for client, status in config_statuses.items() if status.get("status") not in {"ok"}]
    status = "ok" if not issues and not failed_tools and not config_degraded else "degraded"
    plugin_status = "ok" if plugin_ready else "skipped"
    report = {
        "status": status,
        "generated_at": generated_at,
        "project_root": project_root,
        "clients": config_statuses,
        "server": {
            "status": server_status.get("status"),
            "tool_count": server_status.get("server", {}).get("tool_count"),
            "tool_names": server_status.get("server", {}).get("tool_names"),
        },
        "initialize": initialize,
        "tools_list": tools_list,
        "tool_catalog": [{"name": name, "schema": tool_schema(name)} for name in TOOL_ORDER],
        "tool_results": tool_results,
        "plugin_status": {
            "unity_nexus": plugin_status,
            "nexus_connected": bool(nexus.get("connected")),
            "nexus_project": nexus.get("project_path"),
            "project_matches": _project_matches(project_root, nexus.get("project_path")),
        },
        "summary": {
            "tool_count": tools_list.get("tool_count"),
            "smoked_tools": len([item for item in tool_results if item.get("status") == "ok"]),
            "skipped_tools": len([item for item in tool_results if item.get("status") == "skipped"]),
            "failed_tools": failed_tools,
            "config_degraded": config_degraded,
            "duration_ms": round((time.monotonic() - started) * 1000, 1),
        },
        "issues": issues,
        "log_file": str(Path.home() / ".soma" / "logs" / f"soma_{datetime.now(tz=timezone.utc).strftime('%Y%m%d')}.jsonl"),
    }
    return report


def _append_missing_plugin_records(tool_results: list[dict[str, Any]], plugin_ready: bool, project_root: str) -> None:
    existing = {item.get("tool") for item in tool_results}
    reason = "plugin_guarded" if plugin_ready else "plugin_guarded: Nexus offline or project mismatch"
    for tool in TOOL_ORDER:
        if tool not in PLUGIN_TOOLS or tool in existing:
            continue
        started = time.monotonic()
        record = _safe_tool_record(tool, "skipped", started, reason=reason)
        tool_results.append(record)
        _log_tool_record(record, project_root)


def save_report(report: dict[str, Any]) -> None:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(tz=timezone.utc).strftime("%Y%m%d-%H%M%S")
    latest = REPORT_DIR / "latest.json"
    history = REPORT_DIR / f"mcp_smoke_{stamp}.json"
    text = json.dumps(report, indent=2, default=str)
    latest.write_text(text, encoding="utf-8")
    history.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify Soma MCP client configs and live smoke.")
    parser.add_argument("--project-root", default=None)
    parser.add_argument("--clients", default="codex,gemini")
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--timeout", type=float, default=45.0)
    parser.add_argument("--codex-config-path", default=None)
    parser.add_argument("--gemini-config-path", default=None)
    parser.add_argument("--hermes-config-path", default=None)
    parser.add_argument("--no-save", action="store_true")
    parser.add_argument("--strict", action="store_true", help="Return non-zero for degraded reports.")
    args = parser.parse_args()

    report = run_smoke(args)
    if not args.no_save:
        save_report(report)
    log_mcp_event(
        event="mcp_smoke",
        status=report["status"],
        project_root=report["project_root"],
        duration_ms=report.get("summary", {}).get("duration_ms"),
        extra={
            "tool_count": report.get("summary", {}).get("tool_count"),
            "failed_tools": report.get("summary", {}).get("failed_tools"),
            "config_degraded": report.get("summary", {}).get("config_degraded"),
            "report_path": str(REPORT_DIR / "latest.json"),
        },
    )
    print(json.dumps(report, indent=2, default=str))
    return 0 if report["status"] == "ok" or not args.strict else 1


if __name__ == "__main__":
    raise SystemExit(main())

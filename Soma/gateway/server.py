#!/usr/bin/env python3
"""Soma MCP server CLI and stdio entrypoint.

This file is intentionally thin. Tool definitions, config mutation, status
payloads, and JSON-RPC daemon behavior live in focused gateway modules so the
next maintainer can reason about each responsibility separately.
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
from typing import Any

from gateway.client_config import (
    build_client_config,
    codex_config_default_path,
    install_hermes_config,
    install_gemini_config,
    install_codex_config,
    rollback_gemini_config,
    rollback_codex_config,
    server_script_path,
    verify_hermes_config,
    verify_gemini_config,
    verify_codex_config,
)
from gateway.jsonrpc import run_daemon
from gateway.status import (
    build_status_payload,
    discover_nexus,
    find_graph_json,
    graphify,
    get_memory_dir,
    load_memory,
    query_graph_simple,
    save_memory,
)
from gateway.tool_registry import TOOL_CATALOG, call_tool, tool_schema
from soma_audit import context_from_arguments
from soma_logger import log_mcp_request, log_mcp_response, log_server_start, log_server_stop
from soma_project_setup import analyze_project_ai_setup, harden_project_ai_setup, rollback_project_ai_setup
from scout_pipeline import normalize_path

_project_root: str | None = os.environ.get("SOMA_PROJECT_ROOT")

# Backwards-compatible name used by older tests/docs.
def _server_script_path() -> str:
    return server_script_path()


async def _run_requested_tool(tool_name: str, tool_params: dict[str, Any]) -> None:
    try:
        result = await call_tool(tool_name, tool_params)
        print(result)
    except Exception as exc:
        print(json.dumps({"error": str(exc)}))
        sys.exit(1)


async def _run_mcp_package_server(transport: str) -> None:
    from mcp.server import Server
    from mcp.server.stdio import stdio_server
    from mcp.types import TextContent, Tool

    if transport == "sse":
        print(json.dumps({"error": "SSE not currently supported in lightweight python gateway"}))
        sys.exit(1)

    server = Server("soma-gateway")

    @server.list_tools()
    async def handle_list_tools() -> list[Tool]:
        start = log_mcp_request("tools/list", None, 0)
        tools = [
            Tool(name=name, description=func.__doc__ or "Soma tool", inputSchema=tool_schema(name))
            for name, func in TOOL_CATALOG.items()
        ]
        log_mcp_response("tools/list", None, start, "ok", len(str(tools)))
        return tools

    @server.call_tool()
    async def handle_call_tool(name: str, arguments: dict) -> list[TextContent]:
        audit_context = context_from_arguments(arguments)
        start = log_mcp_request(f"tools/call:{name}", None, len(json.dumps(arguments or {}, default=str)), extra=audit_context)
        if name not in TOOL_CATALOG:
            log_mcp_response(f"tools/call:{name}", None, start, "error", 0, extra=audit_context)
            raise ValueError(f"Unknown tool: {name}")
        try:
            result = await call_tool(name, arguments)
            log_mcp_response(f"tools/call:{name}", None, start, "ok", len(str(result)), extra=audit_context)
            return [TextContent(type="text", text=str(result))]
        except Exception as exc:
            text = json.dumps({"status": "failed", "error": str(exc)})
            log_mcp_response(f"tools/call:{name}", None, start, "error", len(text), extra=audit_context)
            return [TextContent(type="text", text=text)]

    async with stdio_server() as (read, write):
        log_server_start(_project_root, os.getpid())
        try:
            await server.run(read, write, server.create_initialization_options())
        finally:
            log_server_stop(os.getpid())


def main() -> None:
    global _project_root
    import argparse

    parser = argparse.ArgumentParser(description="Soma MCP Server")
    parser.add_argument("--transport", default="stdio", choices=["stdio", "sse"])
    parser.add_argument("--port", type=int, default=8090, help="Port for SSE mode")
    parser.add_argument("--project-root", default=None, help="Override project root")
    parser.add_argument("--print-client-config", choices=["codex", "gemini", "claude", "hermes"], default=None)
    parser.add_argument("--status-json", action="store_true", help="Print compact Soma/Nexus/Graphify status and exit")
    parser.add_argument("--graph-storage-json", action="store_true", help="Print managed Graphify storage info and exit")
    parser.add_argument("--check-graphify-tool-json", action="store_true", help="Print installed/latest Graphify tool version info")
    parser.add_argument("--migrate-graph", action="store_true", help="Copy a legacy graphify-out into Soma managed graph storage")
    parser.add_argument("--refresh-managed-graph", action="store_true", help="Refresh the selected project's managed Graphify graph without project-root output")
    parser.add_argument("--refresh-all-managed-graphs", action="store_true", help="Refresh all real indexed managed Graphify graphs")
    parser.add_argument("--full-graph-rebuild", action="store_true", help="Use graphify extract instead of AST-only update for graph refresh")
    parser.add_argument("--force-graph-refresh", action="store_true", help="Pass --force to AST-only graph refresh")
    parser.add_argument("--diagnose-graph-json", action="store_true", help="Run Graphify multigraph diagnostics for the selected graph")
    parser.add_argument("--check-graph-semantic-update-json", action="store_true", help="Check whether semantic graph refresh is pending")
    parser.add_argument("--graph-tree-json", action="store_true", help="Generate managed Graphify tree report and print its path")
    parser.add_argument("--graph-callflow-json", action="store_true", help="Generate managed Graphify callflow report and print its path")
    parser.add_argument("--install-codex-config", action="store_true", help="Back up and install a Soma-only Codex MCP config")
    parser.add_argument("--rollback-codex-config", action="store_true", help="Restore Codex config from the newest Soma backup")
    parser.add_argument("--install-gemini-config", action="store_true", help="Back up and install a Soma-only Gemini MCP config")
    parser.add_argument("--install-hermes-config", action="store_true", help="Back up and install a Soma-only Hermes MCP config")
    parser.add_argument("--rollback-gemini-config", action="store_true", help="Restore Gemini config from the newest Soma backup")
    parser.add_argument("--verify-client-config", choices=["codex", "gemini", "hermes"], default=None, help="Verify a client config points to Soma only")
    parser.add_argument("--analyze-project-ai-setup", action="store_true", help="Analyze global/project AI configs and prompts for Soma-first routing")
    parser.add_argument("--harden-project-ai-setup", action="store_true", help="Back up and rewrite project AI setup for Soma-first routing")
    parser.add_argument("--rollback-project-ai-setup", action="store_true", help="Restore files changed by the latest project AI setup hardening")
    parser.add_argument("--config-path", default=None, help="Override client config path for install/verify")
    parser.add_argument("--backup-path", default=None, help="Explicit backup path for Codex rollback")
    parser.add_argument("--daemon", action="store_true", help="Run as a long-lived Python daemon over stdio")
    parser.add_argument("--run-tool", default=None, help="Tool to run")
    parser.add_argument("tool_args", nargs="*", help="Arguments for the tool (JSON)")
    args = parser.parse_args()

    if args.project_root:
        _project_root = normalize_path(args.project_root)
        os.environ["SOMA_PROJECT_ROOT"] = _project_root

    if args.print_client_config:
        print(build_client_config(args.print_client_config, _project_root, sys.executable))
        raise SystemExit(0)
    if args.status_json:
        print(json.dumps(build_status_payload(_project_root), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.graph_storage_json:
        if not _project_root:
            print(json.dumps({"status": "error", "summary": "--project-root is required for graph storage info"}, indent=2, sort_keys=True))
            raise SystemExit(2)
        print(json.dumps(graphify.storage_info(_project_root), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.check_graphify_tool_json:
        print(json.dumps(graphify.storage.tool_version_status(check_latest=True), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.migrate_graph:
        if not _project_root:
            print(json.dumps({"status": "error", "summary": "--project-root is required for graph migration"}, indent=2, sort_keys=True))
            raise SystemExit(2)
        print(json.dumps(graphify.migrate_graph(_project_root), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.refresh_managed_graph:
        if not _project_root:
            print(json.dumps({"status": "error", "summary": "--project-root is required for graph refresh"}, indent=2, sort_keys=True))
            raise SystemExit(2)
        print(json.dumps(graphify.storage.refresh_managed_graph(_project_root, full=args.full_graph_rebuild, force=args.force_graph_refresh), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.refresh_all_managed_graphs:
        print(json.dumps(graphify.storage.refresh_all_managed_graphs(full=args.full_graph_rebuild), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.diagnose_graph_json:
        if not _project_root:
            print(json.dumps({"status": "error", "summary": "--project-root is required for graph diagnostics"}, indent=2, sort_keys=True))
            raise SystemExit(2)
        print(json.dumps(graphify.storage.diagnose_graph(_project_root), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.check_graph_semantic_update_json:
        if not _project_root:
            print(json.dumps({"status": "error", "summary": "--project-root is required for graph semantic update check"}, indent=2, sort_keys=True))
            raise SystemExit(2)
        print(json.dumps(graphify.storage.check_semantic_update(_project_root), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.graph_tree_json:
        if not _project_root:
            print(json.dumps({"status": "error", "summary": "--project-root is required for graph tree generation"}, indent=2, sort_keys=True))
            raise SystemExit(2)
        print(json.dumps(graphify.storage.generate_tree_report(_project_root), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.graph_callflow_json:
        if not _project_root:
            print(json.dumps({"status": "error", "summary": "--project-root is required for graph callflow generation"}, indent=2, sort_keys=True))
            raise SystemExit(2)
        print(json.dumps(graphify.storage.generate_callflow_report(_project_root), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.verify_client_config == "codex":
        print(json.dumps(verify_codex_config(args.config_path, _project_root), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.verify_client_config == "gemini":
        print(json.dumps(verify_gemini_config(args.config_path, _project_root), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.verify_client_config == "hermes":
        print(json.dumps(verify_hermes_config(args.config_path, _project_root), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.install_codex_config:
        print(json.dumps(install_codex_config(args.config_path, _project_root, sys.executable), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.install_gemini_config:
        print(json.dumps(install_gemini_config(args.config_path, _project_root, sys.executable), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.install_hermes_config:
        print(json.dumps(install_hermes_config(args.config_path, _project_root, sys.executable), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.rollback_codex_config:
        print(json.dumps(rollback_codex_config(args.config_path, args.backup_path), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.rollback_gemini_config:
        print(json.dumps(rollback_gemini_config(args.config_path, args.backup_path), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.analyze_project_ai_setup:
        if not _project_root:
            print(json.dumps({"status": "error", "summary": "--project-root is required for project AI setup analysis"}, indent=2, sort_keys=True))
            raise SystemExit(2)
        print(json.dumps(analyze_project_ai_setup(_project_root), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.harden_project_ai_setup:
        if not _project_root:
            print(json.dumps({"status": "error", "summary": "--project-root is required for project AI setup hardening"}, indent=2, sort_keys=True))
            raise SystemExit(2)
        print(json.dumps(harden_project_ai_setup(_project_root, python_executable=sys.executable), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.rollback_project_ai_setup:
        if not _project_root:
            print(json.dumps({"status": "error", "summary": "--project-root is required for project AI setup rollback"}, indent=2, sort_keys=True))
            raise SystemExit(2)
        print(json.dumps(rollback_project_ai_setup(_project_root), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.daemon:
        asyncio.run(run_daemon(_project_root))
        raise SystemExit(0)
    if args.run_tool:
        tool_params: dict[str, Any] = {}
        if args.tool_args:
            try:
                tool_params = json.loads(args.tool_args[0])
            except Exception:
                pass
        asyncio.run(_run_requested_tool(args.run_tool, tool_params))
        raise SystemExit(0)

    asyncio.run(_run_mcp_package_server(args.transport))


if __name__ == "__main__":
    main()

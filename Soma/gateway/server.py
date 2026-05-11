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
    install_codex_config,
    rollback_codex_config,
    server_script_path,
    verify_codex_config,
)
from gateway.jsonrpc import run_daemon
from gateway.status import (
    build_status_payload,
    discover_nexus,
    find_graph_json,
    get_memory_dir,
    load_memory,
    query_graph_simple,
    save_memory,
)
from gateway.tool_registry import TOOL_CATALOG
from soma_logger import log_mcp_request, log_mcp_response, log_server_start, log_server_stop
from scout_pipeline import normalize_path

_project_root: str | None = os.environ.get("SOMA_PROJECT_ROOT")

# Backwards-compatible name used by older tests/docs.
def _server_script_path() -> str:
    return server_script_path()


async def _run_requested_tool(tool_name: str, tool_params: dict[str, Any]) -> None:
    try:
        if tool_name in TOOL_CATALOG:
            result = await TOOL_CATALOG[tool_name](**tool_params)
        else:
            result = json.dumps({"error": f"Unknown tool {tool_name}"})
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
            Tool(name=name, description=func.__doc__ or "Soma tool", inputSchema={"type": "object", "properties": {}})
            for name, func in TOOL_CATALOG.items()
        ]
        log_mcp_response("tools/list", None, start, "ok", len(str(tools)))
        return tools

    @server.call_tool()
    async def handle_call_tool(name: str, arguments: dict) -> list[TextContent]:
        start = log_mcp_request(f"tools/call:{name}", None, len(json.dumps(arguments or {}, default=str)))
        if name not in TOOL_CATALOG:
            log_mcp_response(f"tools/call:{name}", None, start, "error", 0)
            raise ValueError(f"Unknown tool: {name}")
        try:
            result = await TOOL_CATALOG[name](**arguments)
            log_mcp_response(f"tools/call:{name}", None, start, "ok", len(str(result)))
            return [TextContent(type="text", text=str(result))]
        except Exception as exc:
            text = json.dumps({"status": "failed", "error": str(exc)})
            log_mcp_response(f"tools/call:{name}", None, start, "error", len(text))
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
    parser.add_argument("--print-client-config", choices=["codex", "gemini", "claude"], default=None)
    parser.add_argument("--status-json", action="store_true", help="Print compact Soma/Nexus/Graphify status and exit")
    parser.add_argument("--install-codex-config", action="store_true", help="Back up and install a Soma-only Codex MCP config")
    parser.add_argument("--rollback-codex-config", action="store_true", help="Restore Codex config from the newest Soma backup")
    parser.add_argument("--verify-client-config", choices=["codex"], default=None, help="Verify a client config points to Soma only")
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
    if args.verify_client_config == "codex":
        print(json.dumps(verify_codex_config(args.config_path), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.install_codex_config:
        print(json.dumps(install_codex_config(args.config_path, _project_root, sys.executable), indent=2, sort_keys=True))
        raise SystemExit(0)
    if args.rollback_codex_config:
        print(json.dumps(rollback_codex_config(args.config_path, args.backup_path), indent=2, sort_keys=True))
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

#!/usr/bin/env python3
"""Soma MCP server CLI and stdio entrypoint."""
from __future__ import annotations

import json
import os
import sys
from typing import Any

from gateway.client_config import (
    build_client_config,
    codex_config_default_path,
    install_codex_config,
    install_gemini_config,
    install_hermes_config,
    rollback_codex_config,
    rollback_gemini_config,
    server_script_path,
    verify_codex_config,
    verify_gemini_config,
    verify_hermes_config,
)
from gateway.server_cli import run_gateway_cli
from gateway.status import (
    build_status_payload,
    discover_nexus,
    find_graph_json,
    get_memory_dir,
    graphify,
    load_memory,
    query_graph_simple,
    save_memory,
)
from gateway.tool_registry import TOOL_CATALOG, call_tool, tool_descriptor
from soma_audit import context_from_arguments
from soma_logger import log_mcp_request, log_mcp_response, log_server_start, log_server_stop
from soma_project_setup import analyze_project_ai_setup, harden_project_ai_setup, rollback_project_ai_setup
from scout_pipeline import normalize_path

_project_root: str | None = os.environ.get("SOMA_PROJECT_ROOT")


def _server_script_path() -> str:
    """Backwards-compatible name used by older tests/docs."""
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
        tools = [Tool(**tool_descriptor(name)) for name in TOOL_CATALOG]
        log_mcp_response("tools/list", None, start, "ok", len(str(tools)))
        return tools

    @server.call_tool()
    async def handle_call_tool(name: str, arguments: dict) -> list[TextContent]:
        audit_context = context_from_arguments(arguments)
        start = log_mcp_request(
            f"tools/call:{name}",
            None,
            len(json.dumps(arguments or {}, default=str)),
            extra=audit_context,
        )
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
    _project_root = run_gateway_cli(
        _project_root,
        run_tool=_run_requested_tool,
        run_server=_run_mcp_package_server,
    )


if __name__ == "__main__":
    main()

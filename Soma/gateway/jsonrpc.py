"""Lightweight line-delimited JSON-RPC daemon for Swift-side process control."""

from __future__ import annotations

import json
import os
import sys
from typing import Any

from gateway.tool_registry import TOOL_CATALOG, call_tool, tool_descriptor
from soma_audit import context_from_arguments
from soma_logger import log_mcp_request, log_mcp_response, log_server_start, log_server_stop


async def run_daemon(project_root: str | None = None) -> None:
    import asyncio

    loop = asyncio.get_running_loop()
    log_server_start(project_root, os.getpid())
    while True:
        line = await loop.run_in_executor(None, sys.stdin.readline)
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        await _handle_line(line)
    log_server_stop(os.getpid())


async def _handle_line(line: str) -> None:
    start = None
    method = "unknown"
    req_id = None
    try:
        req = json.loads(line)
        req_id = req.get("id")
        method = req.get("method")
        params = req.get("params", {})
        audit_context = _audit_context_from_request(method, params)
        start = log_mcp_request(method or "unknown", req_id, len(json.dumps(params, default=str)), extra=audit_context)
        res = await _dispatch(method, params)
        response = {"jsonrpc": "2.0", "id": req_id, "result": _result_object(res)}
        response_text = json.dumps(response)
        log_mcp_response(method or "unknown", req_id, start, "ok", len(response_text), extra=audit_context)
        print(response_text, flush=True)
    except Exception as exc:
        try:
            req_id = json.loads(line).get("id")
        except Exception:
            req_id = None
        response = {"jsonrpc": "2.0", "id": req_id, "error": {"code": -32000, "message": str(exc)}}
        response_text = json.dumps(response)
        if start is not None:
            log_mcp_response(method or "unknown", req_id, start, "error", len(response_text))
        print(response_text, flush=True)


def _audit_context_from_request(method: str | None, params: Any) -> dict[str, Any]:
    if not isinstance(params, dict):
        return {}
    if method == "tools/call":
        arguments = params.get("arguments") if isinstance(params.get("arguments"), dict) else {}
        return context_from_arguments(arguments)
    return context_from_arguments(params)


async def _dispatch(method: str | None, params: dict[str, Any]) -> str:
    if method == "initialize":
        return json.dumps(
            {
                "protocolVersion": "2024-11-05",
                "serverInfo": {"name": "soma-gateway", "version": "local"},
                "capabilities": {"tools": {}},
            }
        )
    if method == "tools/list":
        return json.dumps({"tools": [tool_descriptor(name) for name in TOOL_CATALOG]})
    if method == "tools/call":
        name = str(params.get("name") or "")
        arguments = params.get("arguments") if isinstance(params.get("arguments"), dict) else {}
        return await call_tool(name, arguments)
    if method in TOOL_CATALOG:
        return await call_tool(method, params)
    return json.dumps({"error": f"Unknown tool {method}"})


def _result_object(result: str) -> dict[str, Any]:
    try:
        decoded = json.loads(result)
        if isinstance(decoded, dict):
            return decoded
    except Exception:
        pass
    return {"result": result}

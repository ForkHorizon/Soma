#!/usr/bin/env python3
"""
Soma MCP Server - single gateway for Big AI.

Big AI connects only to Soma. Soma composes Scout Pipeline, Nexus Unity,
Graphify, project memory, and optional local model stages into bounded packets.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any

from gateway.core import get_active_project_root, graphify, memory_store, nexus
from gateway.tools.context import soma_code_context, soma_get_map, soma_prepare_context
from gateway.tools.memory import soma_remember
from gateway.tools.nexus import (
    soma_apply,
    soma_delta,
    soma_execute,
    soma_inspect,
    soma_scene,
)
from gateway.tools.query import soma_ask, soma_debug, soma_review

# Swift acts as the primary MCP server now.
# This script acts as a CLI runner for the heavy Python tools.

SOMA_DIR = Path(__file__).parent
sys.path.insert(0, str(SOMA_DIR))
from scout_pipeline import (  # noqa: E402
    normalize_path,
)

GRAPHIFY_GRAPH_DIR = Path.home() / ".soma" / "graphs"
SOMA_MEMORY_DIR = Path.home() / ".soma"
MAX_TEXT_FIELD_CHARS = 8_000
GRAPH_STALE_SECONDS = 24 * 60 * 60

_project_root: str | None = os.environ.get("SOMA_PROJECT_ROOT")
_last_scene_generation: int | None = None


def discover_nexus(force: bool = False) -> dict[str, Any] | None:
    state = nexus.discover(force=force)
    return state.as_dict() if state.connected else None





def find_graph_json(project_root: str | None) -> Path | None:
    graphs = graphify.find_graphs(project_root)
    return graphs[0] if graphs else None


def query_graph_simple(graph_path: Path, question: str) -> str:
    result = graphify.query(question, str(graph_path.parent.parent), budget=1500)
    if result["answers"]:
        return result["answers"][0]["answer"]
    return ""


def get_memory_dir(project_root: str | None) -> Path:
    return memory_store.project_dir(project_root)


def load_memory(project_root: str | None) -> dict[str, Any]:
    return memory_store.load(project_root)


def save_memory(project_root: str | None, memory: dict[str, Any]):
    memory_store.save(project_root, memory)


def _server_script_path() -> str:
    return normalize_path(Path(__file__).parent.parent / 'soma_mcp_server.py')


def build_client_config(client: str, project_root: str | None = None, python_executable: str | None = None) -> str:
    root = normalize_path(project_root) if project_root else ""
    python = python_executable or sys.executable or "/opt/homebrew/bin/python3"
    script = _server_script_path()

    if client == "codex":
        args = f'["{script}", "--project-root", "{root}"]' if root else f'["{script}"]'
        env_line = f'env = {{ SOMA_PROJECT_ROOT = "{root}" }}' if root else "# env = { SOMA_PROJECT_ROOT = \"/absolute/project/root\" }"
        return "\n".join(
            [
                "[mcp_servers.soma]",
                f'command = "{python}"',
                f"args = {args}",
                env_line,
                "# Keep Big AI connected to Soma only; remove direct Unity MCP entries for this workflow.",
            ]
        )

    if client not in {"gemini", "claude"}:
        raise ValueError(f"unknown client: {client}")

    payload = {
        "mcpServers": {
            "soma": {
                "command": python,
                "args": [script] + (["--project-root", root] if root else []),
                "env": {"SOMA_PROJECT_ROOT": root} if root else {},
            }
        },
        "_note": f"Merge this into {client} MCP settings. Keep Big AI connected only to Soma.",
    }
    return json.dumps(payload, indent=2, sort_keys=True)


def codex_config_default_path() -> Path:
    return Path.home() / ".codex" / "config.toml"


def _timestamp() -> str:
    return time.strftime("%Y%m%d-%H%M%S")


def _backup_path(config_path: Path) -> Path:
    base = config_path.with_name(f"{config_path.name}.soma-backup-{_timestamp()}")
    if not base.exists():
        return base
    index = 1
    while True:
        candidate = config_path.with_name(f"{config_path.name}.soma-backup-{_timestamp()}-{index}")
        if not candidate.exists():
            return candidate
        index += 1


def _codex_backup_candidates(config_path: Path) -> list[Path]:
    return sorted(
        config_path.parent.glob(f"{config_path.name}.soma-backup-*"),
        key=lambda path: (path.stat().st_mtime, path.name),
        reverse=True,
    )


def _remove_toml_table_block(text: str, table_name: str) -> tuple[str, int]:
    header_pattern = re.compile(rf"^\s*\[{re.escape(table_name)}\]\s*(?:#.*)?$")
    any_header_pattern = re.compile(r"^\s*\[")
    lines = text.splitlines()
    kept: list[str] = []
    removed = 0
    skipping = False

    for line in lines:
        if header_pattern.match(line):
            skipping = True
            removed += 1
            continue
        if skipping and any_header_pattern.match(line):
            skipping = False
        if skipping:
            continue
        kept.append(line)

    return "\n".join(kept).strip(), removed


def _count_toml_table(text: str, table_name: str) -> int:
    pattern = re.compile(rf"^\s*\[{re.escape(table_name)}\]\s*(?:#.*)?$", re.MULTILINE)
    return len(pattern.findall(text))


def install_codex_config(
    config_path: str | Path | None = None,
    project_root: str | None = None,
    python_executable: str | None = None,
) -> dict[str, Any]:
    path = Path(config_path).expanduser() if config_path else codex_config_default_path()
    existing = path.read_text(errors="replace") if path.exists() else ""
    backup: Path | None = None
    if path.exists():
        backup = _backup_path(path)
        backup.write_text(existing)

    cleaned, old_soma_blocks = _remove_toml_table_block(existing, "mcp_servers.soma")
    cleaned, direct_nexus_blocks = _remove_toml_table_block(cleaned, "mcp_servers.nexus-unity")
    cleaned = cleaned.strip()
    soma_config = build_client_config("codex", project_root, python_executable).strip()
    updated = f"{cleaned}\n\n{soma_config}\n" if cleaned else f"{soma_config}\n"

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(updated)

    verification = verify_codex_config(path)
    return {
        "status": verification["status"],
        "summary": "Installed Codex MCP config for Soma.",
        "config_path": str(path),
        "backup_path": str(backup) if backup else None,
        "soma_installed": verification["soma_installed"],
        "direct_nexus_removed": direct_nexus_blocks > 0,
        "old_soma_blocks_replaced": old_soma_blocks,
        "issues": verification["issues"],
    }


def rollback_codex_config(
    config_path: str | Path | None = None,
    backup_path: str | Path | None = None,
) -> dict[str, Any]:
    path = Path(config_path).expanduser() if config_path else codex_config_default_path()
    selected_backup: Path | None
    if backup_path:
        selected_backup = Path(backup_path).expanduser()
    else:
        candidates = _codex_backup_candidates(path)
        selected_backup = candidates[0] if candidates else None

    if not selected_backup or not selected_backup.exists():
        return {
            "status": "degraded",
            "summary": "No Codex Soma backup found to restore.",
            "config_path": str(path),
            "backup_path": str(selected_backup) if selected_backup else None,
            "restored": False,
            "issues": ["missing_backup"],
        }

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(selected_backup.read_text(errors="replace"))
    verification = verify_codex_config(path)
    return {
        "status": "ok",
        "summary": "Restored Codex config from Soma backup.",
        "config_path": str(path),
        "backup_path": str(selected_backup),
        "restored": True,
        "post_restore_status": verification["status"],
        "post_restore_issues": verification["issues"],
    }


def verify_codex_config(config_path: str | Path | None = None) -> dict[str, Any]:
    path = Path(config_path).expanduser() if config_path else codex_config_default_path()
    issues: list[str] = []
    if not path.exists():
        return {
            "status": "degraded",
            "summary": "Codex config file not found.",
            "config_path": str(path),
            "soma_installed": False,
            "direct_nexus_exposed": False,
            "tool_exposure_clean": False,
            "issues": ["missing_config"],
        }

    text = path.read_text(errors="replace")
    soma_blocks = _count_toml_table(text, "mcp_servers.soma")
    has_soma_script = "soma_mcp_server.py" in text
    direct_nexus_exposed = any(marker in text for marker in ("[mcp_servers.nexus-unity]", "nexus_unity_bridge", "nexus-unity"))
    unity_tool_exposed = "unity_" in text

    if soma_blocks != 1:
        issues.append(f"soma_table_count={soma_blocks}")
    if not has_soma_script:
        issues.append("soma_script_missing")
    if direct_nexus_exposed:
        issues.append("direct_nexus_exposed")
    if unity_tool_exposed:
        issues.append("unity_tool_marker_found")

    clean = not direct_nexus_exposed and not unity_tool_exposed
    return {
        "status": "ok" if soma_blocks == 1 and has_soma_script and clean else "degraded",
        "summary": "Codex config points to Soma only." if soma_blocks == 1 and has_soma_script and clean else "Codex config needs Soma-only cleanup.",
        "config_path": str(path),
        "soma_installed": soma_blocks == 1 and has_soma_script,
        "direct_nexus_exposed": direct_nexus_exposed,
        "tool_exposure_clean": clean,
        "issues": issues,
    }


def build_status_payload(project_root: str | None = None) -> dict[str, Any]:
    root = normalize_path(project_root) if project_root else get_active_project_root()
    state = nexus.discover(force=True)
    # In migration phase, hardcode the known tools since FastMCP is removed
    tools = [
        "soma_prepare_context", "soma_get_map", "soma_ask", "soma_inspect",
        "soma_scene", "soma_execute", "soma_debug", "soma_delta",
        "soma_apply", "soma_remember", "soma_review", "soma_code_context"
    ]
    return {
        "status": "ok",
        "server": {
            "transport": "stdio",
            "script": _server_script_path(),
            "tool_count": len(tools),
            "tool_names": tools,
        },
        "project_root": root,
        "nexus": state.as_dict(),
        "graph": graphify.status(root),
        "python": sys.executable,
    }


def main():
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
    parser.add_argument("--run-tool", default=None, help="Tool to run")
    parser.add_argument("tool_args", nargs="*", help="Arguments for the tool (JSON)")
    args = parser.parse_args()

    if args.project_root:
        _project_root = normalize_path(args.project_root)

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

    import asyncio

    if args.run_tool:
        tool_name = args.run_tool
        tool_params = {}
        if args.tool_args:
            try:
                tool_params = json.loads(args.tool_args[0])
            except Exception:
                pass

        async def run_requested_tool():
            try:
                if tool_name == "soma_prepare_context":
                    res = await soma_prepare_context(**tool_params)
                elif tool_name == "soma_get_map":
                    res = await soma_get_map(**tool_params)
                elif tool_name == "soma_ask":
                    res = await soma_ask(**tool_params)
                elif tool_name == "soma_inspect":
                    res = await soma_inspect(**tool_params)
                elif tool_name == "soma_scene":
                    res = await soma_scene(**tool_params)
                elif tool_name == "soma_execute":
                    res = await soma_execute(**tool_params)
                elif tool_name == "soma_debug":
                    res = await soma_debug(**tool_params)
                elif tool_name == "soma_delta":
                    res = await soma_delta(**tool_params)
                elif tool_name == "soma_apply":
                    res = await soma_apply(**tool_params)
                elif tool_name == "soma_remember":
                    res = await soma_remember(**tool_params)
                elif tool_name == "soma_review":
                    res = await soma_review(**tool_params)
                elif tool_name == "soma_code_context":
                    res = await soma_code_context(**tool_params)
                else:
                    res = json.dumps({"error": f"Unknown tool {tool_name}"})
                print(res)
            except Exception as e:
                print(json.dumps({"error": str(e)}))
                sys.exit(1)

        asyncio.run(run_requested_tool())
        raise SystemExit(0)

    # If no specific tool is requested, run as a standard MCP server using Anthropic's mcp pip package
    from mcp.server import Server
    from mcp.server.stdio import stdio_server
    from mcp.types import Tool, TextContent

    server = Server("soma-gateway")
    
    TOOL_CATALOG = {
        "soma_prepare_context": soma_prepare_context,
        "soma_get_map": soma_get_map,
        "soma_ask": soma_ask,
        "soma_inspect": soma_inspect,
        "soma_scene": soma_scene,
        "soma_execute": soma_execute,
        "soma_debug": soma_debug,
        "soma_delta": soma_delta,
        "soma_apply": soma_apply,
        "soma_remember": soma_remember,
        "soma_review": soma_review,
        "soma_code_context": soma_code_context,
    }

    @server.list_tools()
    async def handle_list_tools() -> list[Tool]:
        return [
            Tool(name=name, description=func.__doc__ or "Soma tool", inputSchema={"type": "object", "properties": {}})
            for name, func in TOOL_CATALOG.items()
        ]

    @server.call_tool()
    async def handle_call_tool(name: str, arguments: dict) -> list[TextContent]:
        if name not in TOOL_CATALOG:
            raise ValueError(f"Unknown tool: {name}")
        try:
            # Most of the tools return a string representation of a JSON packet
            res = await TOOL_CATALOG[name](**arguments)
            return [TextContent(type="text", text=str(res))]
        except Exception as e:
            return [TextContent(type="text", text=json.dumps({"status": "failed", "error": str(e)}))]

    async def run_server():
        if args.transport == "sse":
            print(json.dumps({"error": "SSE not currently supported in lightweight python gateway"}))
            sys.exit(1)
        async with stdio_server() as (read, write):
            await server.run(read, write, server.create_initialization_options())

    asyncio.run(run_server())

if __name__ == "__main__":
    main()

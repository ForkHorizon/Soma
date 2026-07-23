from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from typing import Any, Awaitable, Callable

from gateway.client_config import (
    build_client_config,
    install_codex_config,
    install_gemini_config,
    install_hermes_config,
    rollback_codex_config,
    rollback_gemini_config,
    verify_codex_config,
    verify_gemini_config,
    verify_hermes_config,
)
from gateway.jsonrpc import run_daemon
from gateway.status import build_status_payload, graphify
from extension_manager import project_overview, scan_ai_clients, setup_memory_tools, setup_project_tool, sync_ai_clients, sync_project_clients, tool_status, update_tool, verify_ai_clients
from soma_project_setup import analyze_project_ai_setup, harden_project_ai_setup, rollback_project_ai_setup
from scout_pipeline import normalize_path

ToolRunner = Callable[[str, dict[str, Any]], Awaitable[None]]
ServerRunner = Callable[[str], Awaitable[None]]


def run_gateway_cli(project_root: str | None, *, run_tool: ToolRunner, run_server: ServerRunner) -> str | None:
    args = _parse_args()
    project_root = _apply_project_root(args, project_root)
    handled = (
        _handle_status_commands(args, project_root)
        or _handle_graph_commands(args, project_root)
        or _handle_config_commands(args, project_root)
        or _handle_project_setup_commands(args, project_root)
    )
    if handled:
        raise SystemExit(0)
    if args.daemon:
        asyncio.run(run_daemon(project_root))
        raise SystemExit(0)
    if args.run_tool:
        asyncio.run(run_tool(args.run_tool, _tool_params(args.tool_args)))
        raise SystemExit(0)
    asyncio.run(run_server(args.transport))
    return project_root


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Soma MCP Server")
    parser.add_argument("--transport", default="stdio", choices=["stdio", "sse"])
    parser.add_argument("--port", type=int, default=8090, help="Port for SSE mode")
    parser.add_argument("--project-root", default=None, help="Override project root")
    parser.add_argument("--print-client-config", choices=["codex", "gemini", "claude", "hermes"], default=None)
    parser.add_argument("--status-json", action="store_true", help="Print compact Soma/Nexus/Graphify status and exit")
    parser.add_argument("--graph-storage-json", action="store_true", help="Print managed Graphify storage info and exit")
    parser.add_argument("--check-graphify-tool-json", action="store_true", help="Print installed/latest Graphify tool version info")
    parser.add_argument("--tool-status-json", nargs="?", const="all", default=None, help="Print managed extension tool version info")
    parser.add_argument("--project-overview-json", action="store_true", help="Print selected project overview for the Soma Projects UI")
    parser.add_argument("--update-tool", choices=["codebase-memory", "graphify", "ponytail", "serena", "projectmem"], default=None, help="Update one managed extension tool and verify clients")
    parser.add_argument("--setup-memory-tools", action="store_true", help="Install and initialize Codebase-Memory and projectmem for the selected project")
    parser.add_argument("--setup-project-tool", choices=["codebase-memory", "projectmem", "graphify"], default=None, help="Install or initialize one extension tool for the selected project")
    parser.add_argument("--scan-ai-clients-json", action="store_true", help="Scan known project/client AI config locations")
    parser.add_argument("--verify-ai-clients-json", action="store_true", help="Verify known AI client configs")
    parser.add_argument("--sync-ai-clients", action="store_true", help="Install/repair known AI client configs for Soma")
    parser.add_argument("--sync-project-clients", action="store_true", help="Repair only project-local AI client configs for the selected project")
    parser.add_argument("--recent-project-root", action="append", default=[], help="Additional project root to scan/verify")
    parser.add_argument("--migrate-graph", action="store_true", help="Copy a legacy graphify-out into Soma managed graph storage")
    parser.add_argument("--refresh-managed-graph", action="store_true", help="Refresh the selected project's managed Graphify graph without project-root output")
    parser.add_argument("--refresh-all-managed-graphs", action="store_true", help="Refresh all real indexed managed Graphify graphs")
    parser.add_argument("--full-graph-rebuild", action="store_true", help="Use graphify extract instead of AST-only update for graph refresh")
    parser.add_argument("--force-graph-refresh", action="store_true", help="Pass --force to AST-only graph refresh")
    parser.add_argument("--diagnose-graph-json", action="store_true", help="Run Graphify multigraph diagnostics for the selected graph")
    parser.add_argument("--check-graph-semantic-update-json", action="store_true", help="Check whether semantic graph refresh is pending")
    parser.add_argument("--graph-tree-json", action="store_true", help="Generate managed Graphify tree report and print its path")
    parser.add_argument("--graph-callflow-json", action="store_true", help="Generate managed Graphify callflow report and print its path")
    _add_config_args(parser)
    _add_project_setup_args(parser)
    parser.add_argument("--daemon", action="store_true", help="Run as a long-lived Python daemon over stdio")
    parser.add_argument("--run-tool", default=None, help="Tool to run")
    parser.add_argument("tool_args", nargs="*", help="Arguments for the tool (JSON)")
    return parser.parse_args()


def _add_config_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--install-codex-config", action="store_true", help="Back up and install a Soma-only Codex MCP config")
    parser.add_argument("--rollback-codex-config", action="store_true", help="Restore Codex config from the newest Soma backup")
    parser.add_argument("--install-gemini-config", action="store_true", help="Back up and install a Soma-only Gemini MCP config")
    parser.add_argument("--install-hermes-config", action="store_true", help="Back up and install a Soma-only Hermes MCP config")
    parser.add_argument("--rollback-gemini-config", action="store_true", help="Restore Gemini config from the newest Soma backup")
    parser.add_argument("--verify-client-config", choices=["codex", "gemini", "hermes"], default=None, help="Verify a client config points to Soma only")
    parser.add_argument("--config-path", default=None, help="Override client config path for install/verify")
    parser.add_argument("--backup-path", default=None, help="Explicit backup path for Codex rollback")


def _add_project_setup_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--analyze-project-ai-setup", action="store_true", help="Analyze global/project AI configs and prompts for Soma-first routing")
    parser.add_argument("--harden-project-ai-setup", action="store_true", help="Back up and rewrite project AI setup for Soma-first routing")
    parser.add_argument("--rollback-project-ai-setup", action="store_true", help="Restore files changed by the latest project AI setup hardening")


def _apply_project_root(args: argparse.Namespace, project_root: str | None) -> str | None:
    if not args.project_root:
        return project_root
    normalized = normalize_path(args.project_root)
    os.environ["SOMA_PROJECT_ROOT"] = normalized
    return normalized


def _handle_status_commands(args: argparse.Namespace, project_root: str | None) -> bool:
    if args.print_client_config:
        _emit(build_client_config(args.print_client_config, project_root, sys.executable), raw=True)
        return True
    if args.status_json:
        _emit(build_status_payload(project_root))
        return True
    if args.check_graphify_tool_json:
        _emit(graphify.storage.tool_version_status(check_latest=True))
        return True
    if args.tool_status_json:
        _emit(tool_status(args.tool_status_json))
        return True
    if args.project_overview_json:
        _require_project_root(project_root, "project overview")
        _emit(project_overview(project_root, args.recent_project_root, graph_status=graphify.status(project_root)))
        return True
    if args.update_tool:
        _emit(update_tool(args.update_tool, project_root, args.recent_project_root))
        return True
    if args.scan_ai_clients_json:
        _emit(scan_ai_clients(project_root, args.recent_project_root))
        return True
    if args.verify_ai_clients_json:
        _emit(verify_ai_clients(project_root, args.recent_project_root))
        return True
    if args.sync_ai_clients:
        _emit(sync_ai_clients(project_root, args.recent_project_root))
        return True
    if args.sync_project_clients:
        _require_project_root(project_root, "project-local client sync")
        _emit(sync_project_clients(project_root))
        return True
    if args.setup_memory_tools:
        _require_project_root(project_root, "memory tools setup")
        _emit(setup_memory_tools(project_root))
        return True
    if args.setup_project_tool:
        _require_project_root(project_root, "project tool setup")
        if args.setup_project_tool == "graphify":
            _emit(_setup_graphify_project(project_root))
        else:
            _emit(setup_project_tool(args.setup_project_tool, project_root))
        return True
    return False


def _setup_graphify_project(project_root: str | None) -> dict[str, Any]:
    graph = graphify.storage.refresh_managed_graph(project_root)
    issues = graph.get("issues") or graph.get("warnings") or ([] if graph.get("status") == "ok" else [graph.get("summary", "graphify_setup_failed")])
    return {
        "status": "ok" if graph.get("status") == "ok" and not issues else "degraded",
        "summary": "Graphify graph is ready for the selected project." if graph.get("status") == "ok" and not issues else graph.get("summary", "Graphify setup finished with issues."),
        "tool_id": "graphify",
        "name": "Graphify",
        "project_root": project_root,
        "graph": graph,
        "issues": issues,
    }


def _handle_graph_commands(args: argparse.Namespace, project_root: str | None) -> bool:
    commands = [
        (args.graph_storage_json, "graph storage info", lambda: graphify.storage_info(project_root)),
        (args.migrate_graph, "graph migration", lambda: graphify.migrate_graph(project_root)),
        (args.refresh_managed_graph, "graph refresh", lambda: graphify.storage.refresh_managed_graph(project_root, full=args.full_graph_rebuild, force=args.force_graph_refresh)),
        (args.diagnose_graph_json, "graph diagnostics", lambda: graphify.storage.diagnose_graph(project_root)),
        (args.check_graph_semantic_update_json, "graph semantic update check", lambda: graphify.storage.check_semantic_update(project_root)),
        (args.graph_tree_json, "graph tree generation", lambda: graphify.storage.generate_tree_report(project_root)),
        (args.graph_callflow_json, "graph callflow generation", lambda: graphify.storage.generate_callflow_report(project_root)),
    ]
    for enabled, label, action in commands:
        if enabled:
            _require_project_root(project_root, label)
            _emit(action())
            return True
    if args.refresh_all_managed_graphs:
        _emit(graphify.storage.refresh_all_managed_graphs(full=args.full_graph_rebuild))
        return True
    return False


def _handle_config_commands(args: argparse.Namespace, project_root: str | None) -> bool:
    verify_actions = {
        "codex": lambda: verify_codex_config(args.config_path, project_root),
        "gemini": lambda: verify_gemini_config(args.config_path, project_root),
        "hermes": lambda: verify_hermes_config(args.config_path, project_root),
    }
    if args.verify_client_config:
        _emit(verify_actions[args.verify_client_config]())
        return True
    config_actions = [
        (args.install_codex_config, lambda: install_codex_config(args.config_path, project_root, sys.executable)),
        (args.install_gemini_config, lambda: install_gemini_config(args.config_path, project_root, sys.executable)),
        (args.install_hermes_config, lambda: install_hermes_config(args.config_path, project_root, sys.executable)),
        (args.rollback_codex_config, lambda: rollback_codex_config(args.config_path, args.backup_path)),
        (args.rollback_gemini_config, lambda: rollback_gemini_config(args.config_path, args.backup_path)),
    ]
    return _emit_first_enabled(config_actions)


def _handle_project_setup_commands(args: argparse.Namespace, project_root: str | None) -> bool:
    actions = [
        (args.analyze_project_ai_setup, "project AI setup analysis", lambda: analyze_project_ai_setup(project_root)),
        (args.harden_project_ai_setup, "project AI setup hardening", lambda: harden_project_ai_setup(project_root, python_executable=sys.executable)),
        (args.rollback_project_ai_setup, "project AI setup rollback", lambda: rollback_project_ai_setup(project_root)),
    ]
    for enabled, label, action in actions:
        if enabled:
            _require_project_root(project_root, label)
            _emit(action())
            return True
    return False


def _emit_first_enabled(actions: list[tuple[bool, Callable[[], Any]]]) -> bool:
    for enabled, action in actions:
        if enabled:
            _emit(action())
            return True
    return False


def _require_project_root(project_root: str | None, label: str) -> None:
    if project_root:
        return
    _emit({"status": "error", "summary": f"--project-root is required for {label}"})
    raise SystemExit(2)


def _tool_params(tool_args: list[str]) -> dict[str, Any]:
    if not tool_args:
        return {}
    try:
        decoded = json.loads(tool_args[0])
    except Exception:
        return {}
    return decoded if isinstance(decoded, dict) else {}


def _emit(payload: Any, *, raw: bool = False) -> None:
    if raw:
        print(payload)
    else:
        print(json.dumps(payload, indent=2, sort_keys=True))

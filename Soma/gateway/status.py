"""Gateway status helpers used by CLI, Swift UI, and tests."""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from gateway.client_config import server_script_path
from gateway.core import get_active_project_root, graphify, memory_store, nexus
from gateway.tool_registry import TOOL_ORDER
from scout_pipeline import normalize_path


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


def build_status_payload(project_root: str | None = None) -> dict[str, Any]:
    root = normalize_path(project_root) if project_root else get_active_project_root()
    state = nexus.discover(force=True)
    return {
        "status": "ok",
        "server": {
            "transport": "stdio",
            "script": server_script_path(),
            "tool_count": len(TOOL_ORDER),
            "tool_names": TOOL_ORDER,
        },
        "project_root": root,
        "nexus": state.as_dict(),
        "graph": graphify.status(root),
        "python": sys.executable,
    }

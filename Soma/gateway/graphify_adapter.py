from __future__ import annotations

import subprocess
import os
from pathlib import Path
from typing import Any

from gateway.graph_storage import GRAPHIFY_BASE_DIR, GraphStorageManager

class GraphifyAdapter:
    def __init__(self, graph_dir: Path = GRAPHIFY_BASE_DIR):
        self.storage = GraphStorageManager(graph_dir)
        self.graph_dir = self.storage.base_dir

    def project_graph_candidates(self, project_root: str | None) -> list[Path]:
        if not project_root:
            return []
        managed = self.storage.managed_graph_candidates(project_root)
        legacy = [path / "graph.json" for path in self.storage.legacy_graph_dirs(project_root)]
        return _dedupe_paths(managed + legacy)

    def find_graphs(self, project_root: str | None, project_only: bool | None = None) -> list[Path]:
        if project_only is None:
            project_only = os.environ.get("SOMA_GRAPHIFY_PROJECT_ONLY", "1") == "1"
        # Soma no longer falls back to hard-coded cross-project graphs. A false
        # project_only value is accepted for compatibility but still stays scoped
        # to the selected project and its managed storage.
        graphs: list[Path] = []
        for candidate in self.project_graph_candidates(project_root):
            if candidate.exists() and candidate not in graphs:
                graphs.append(candidate)
        return graphs

    def status(self, project_root: str | None) -> dict[str, Any]:
        return self.storage.status(project_root)

    def storage_info(self, project_root: str | None) -> dict[str, Any]:
        return self.storage.storage_info(project_root)

    def migrate_graph(self, project_root: str | None) -> dict[str, Any]:
        return self.storage.migrate_graph(project_root)

    def query(self, question: str, project_root: str | None, budget: int = 1500, project_only: bool | None = None) -> dict[str, Any]:
        graphs = self.find_graphs(project_root, project_only=project_only)
        graph_status = self.status(project_root)
        answers: list[dict[str, str]] = []
        warnings: list[str] = []
        for graph in graphs[:2]:
            try:
                result = subprocess.run(
                    ["graphify", "query", question, "--graph", str(graph), "--budget", str(budget)],
                    capture_output=True,
                    text=True,
                    timeout=15,
                    check=False,
                )
            except Exception as exc:
                warnings.append(f"{graph}: {exc}")
                continue
            stderr = result.stderr.strip()
            if stderr:
                warnings.append(stderr.splitlines()[0])
            if result.returncode == 0 and result.stdout.strip():
                answers.append({"graph": str(graph), "answer": result.stdout.strip()[: max(400, budget * 5)]})
        if not graphs:
            warnings.append("graphify skipped: no project graph found")
        return {
            "graphs": [str(graph) for graph in graphs],
            "answers": answers,
            "warnings": warnings,
            "project_only": project_only if project_only is not None else True,
            "storage_kind": graph_status.get("storage_kind"),
            "managed_available": graph_status.get("managed_available"),
            "legacy_available": graph_status.get("legacy_available"),
        }

    def god_nodes_from_report(self, project_root: str | None, limit: int = 8) -> list[str]:
        nodes: list[str] = []
        for graph in self.find_graphs(project_root):
            report = graph.parent / "GRAPH_REPORT.md"
            if not report.exists():
                continue
            in_section = False
            for line in report.read_text(errors="replace").splitlines():
                if line.startswith("## God Nodes"):
                    in_section = True
                    continue
                if in_section and line.startswith("## "):
                    break
                if in_section and line.strip().startswith(tuple(f"{i}." for i in range(1, 10))):
                    nodes.append(line.strip())
                    if len(nodes) >= limit:
                        return nodes
        return nodes


def _dedupe_paths(paths: list[Path]) -> list[Path]:
    seen: set[str] = set()
    result: list[Path] = []
    for path in paths:
        key = str(path.expanduser().resolve(strict=False))
        if key in seen:
            continue
        seen.add(key)
        result.append(path)
    return result

from __future__ import annotations

import subprocess
import time
import os
from pathlib import Path
from typing import Any

GRAPHIFY_GRAPH_DIR = Path.home() / '.soma' / 'graphs'
GRAPH_STALE_SECONDS = 24 * 60 * 60

class GraphifyAdapter:
    def __init__(self, graph_dir: Path = GRAPHIFY_GRAPH_DIR):
        self.graph_dir = graph_dir

    def project_graph_candidates(self, project_root: str | None) -> list[Path]:
        if not project_root:
            return []
        root = Path(project_root)
        return [
            root / "graphify-out" / "graph.json",
            root / "Assets" / "NexusUnity" / "graphify-out" / "graph.json",
            self.graph_dir / root.name / "graph.json",
        ]

    def find_graphs(self, project_root: str | None, project_only: bool | None = None) -> list[Path]:
        graphs: list[Path] = []
        for candidate in self.project_graph_candidates(project_root):
            if candidate.exists() and candidate not in graphs:
                graphs.append(candidate)

        if project_only is None:
            project_only = os.environ.get("SOMA_GRAPHIFY_PROJECT_ONLY", "1") == "1"
        if not project_only:
            cross_project = [
                Path("/Users/daliys/Daliys/Swift/Soma/graphify-out/graph.json"),
                Path("/Users/daliys/Daliys/UnityProjects/UnityTestForNexus/graphify-out/graph.json"),
            ]
            for candidate in cross_project:
                if candidate.exists() and candidate not in graphs:
                    graphs.append(candidate)
        return graphs

    def status(self, project_root: str | None) -> dict[str, Any]:
        graphs = self.find_graphs(project_root)
        project_graphs = [candidate for candidate in self.project_graph_candidates(project_root) if candidate.exists()]
        now = time.time()
        entries = []
        for graph in graphs[:4]:
            try:
                stat = graph.stat()
                age_seconds = max(0, int(now - stat.st_mtime))
                entries.append(
                    {
                        "path": str(graph),
                        "exists": True,
                        "age_seconds": age_seconds,
                        "stale": age_seconds > GRAPH_STALE_SECONDS,
                        "report_exists": (graph.parent / "GRAPH_REPORT.md").exists(),
                    }
                )
            except OSError as exc:
                entries.append({"path": str(graph), "exists": False, "error": str(exc), "stale": True})
        return {
            "available": bool(graphs),
            "project_graph_available": bool(project_graphs),
            "stale": any(entry.get("stale") for entry in entries) if entries else True,
            "graphs": entries,
            "recommended_action": None if project_graphs else "Run graphify in the project root.",
        }

    def query(self, question: str, project_root: str | None, budget: int = 1500, project_only: bool | None = None) -> dict[str, Any]:
        graphs = self.find_graphs(project_root, project_only=project_only)
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
        return {"graphs": [str(graph) for graph in graphs], "answers": answers, "warnings": warnings, "project_only": project_only if project_only is not None else True}

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

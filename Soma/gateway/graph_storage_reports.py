from __future__ import annotations

import json
import re
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any

from .graph_storage_utils import GRAPH_STALE_SECONDS, dedupe_paths, diagnostic_degraded_reason, version_tuple


class GraphStorageReportsMixin:
    def check_semantic_update(self, project_root: str | Path | None) -> dict[str, Any]:
        root = self.normalize_project_root(project_root)
        if root is None:
            return {"status": "error", "summary": "project_root is required"}
        source_root = self.graph_source_root(root)
        if source_root is None:
            return {"status": "error", "summary": "Graph source root is unavailable.", "pending": None}
        if not self.graph_json(root).exists():
            return {"status": "skipped", "summary": "No managed graph found.", "pending": False}
        result = self._run_semantic_check(root, source_root)
        if isinstance(result, dict):
            return result
        output = "\n".join(part.strip() for part in (result.stdout, result.stderr) if part.strip())
        pending = bool(re.search(r"\b(needs?_update|pending|semantic)\b", output, re.IGNORECASE))
        return {
            "status": "ok" if result.returncode == 0 else "error",
            "summary": output[:1000] if output else "No semantic refresh pending.",
            "pending": pending,
            "returncode": result.returncode,
            "graphSourceRoot": str(source_root),
            "graph_source_root": str(source_root),
        }

    def diagnose_graph(self, project_root: str | Path | None) -> dict[str, Any]:
        root = self.normalize_project_root(project_root)
        graph_path = self._selected_graph_path(root)
        if graph_path is None:
            return {"status": "skipped", "summary": "No project graph found.", "degraded": False}
        result = self._run_diagnostics(graph_path)
        if isinstance(result, dict):
            return result
        try:
            payload = json.loads(result.stdout)
        except Exception as exc:
            return {
                "status": "error",
                "summary": f"Diagnostics JSON unreadable: {exc}",
                "degraded": True,
                "reason": str(exc),
            }
        summary = payload.get("summary") if isinstance(payload, dict) else {}
        degraded, reason = diagnostic_degraded_reason(summary if isinstance(summary, dict) else {})
        diagnostics_path = graph_path.parent / "GRAPH_DIAGNOSE.json"
        self._write_diagnostics(diagnostics_path, payload)
        return self._diagnostics_payload(
            summary if isinstance(summary, dict) else {}, diagnostics_path, degraded, reason
        )

    def generate_tree_report(self, project_root: str | Path | None) -> dict[str, Any]:
        root, graph_path = self._report_root_and_graph(project_root)
        if graph_path is None:
            return {"status": "error", "summary": "No project graph found."}
        source_root = self.graph_source_root(root)
        output = graph_path.parent / "GRAPH_TREE.html"
        cmd = [
            self._graphify_bin(),
            "tree",
            "--graph",
            str(graph_path),
            "--output",
            str(output),
            "--root",
            str(source_root or root),
            "--label",
            root.name if root else "Project",
        ]
        return self._run_graph_report_command(cmd, output, root)

    def generate_callflow_report(self, project_root: str | Path | None) -> dict[str, Any]:
        root, graph_path = self._report_root_and_graph(project_root)
        if graph_path is None:
            return {"status": "error", "summary": "No project graph found."}
        name = re.sub(r"[^A-Za-z0-9_.-]+", "-", root.name if root else "project").strip("-") or "project"
        output = graph_path.parent / f"{name}-callflow.html"
        cmd = [self._graphify_bin(), "export", "callflow-html", "--graph", str(graph_path), "--output", str(output)]
        return self._run_graph_report_command(cmd, output, root)

    def update_index(self, project_root: Path, status: dict[str, Any], graphify_version: str | None = None) -> None:
        data = self.read_index()
        existing = data["projects"].get(self.project_id(project_root), {})
        data["projects"][self.project_id(project_root)] = self._index_payload(
            project_root, status, existing, graphify_version
        )
        try:
            self.write_index(data)
        except Exception:
            pass

    def _index_payload(
        self, project_root: Path, status: dict[str, Any], existing: dict[str, Any], graphify_version: str | None
    ) -> dict[str, Any]:
        selected_path = status.get("storagePath") or status.get("storage_path")
        last_updated = self._graph_last_updated(selected_path, existing)
        return {
            "projectRoot": str(project_root),
            "displayName": project_root.name,
            "graphSourceRoot": status.get("graphSourceRoot")
            or status.get("graph_source_root")
            or existing.get("graphSourceRoot"),
            "graphScope": status.get("graphScope") or status.get("graph_scope") or self.graph_scope(project_root),
            "graphifyVersion": graphify_version
            or status.get("graphifyVersion")
            or status.get("graphify_version")
            or existing.get("graphifyVersion"),
            "lastUpdated": last_updated or int(time.time()),
            "nodeCount": status.get("nodeCount") or status.get("node_count"),
            "edgeCount": status.get("edgeCount") or status.get("edge_count"),
            "storagePath": selected_path,
            "legacyPaths": status.get("legacyPaths") or status.get("legacy_paths") or [],
        }

    def _index_entry(self, project_root: Path | None) -> dict[str, Any]:
        if project_root is None:
            return {}
        entry = self.read_index().get("projects", {}).get(self.project_id(project_root), {})
        return entry if isinstance(entry, dict) else {}

    def _graph_entry(self, graph_path: Path, project_root: Path | None, storage_kind: str) -> dict[str, Any]:
        try:
            stat = graph_path.stat()
            node_count, edge_count = self.count_graph(graph_path)
        except OSError as exc:
            return {
                "path": str(graph_path),
                "storageKind": storage_kind,
                "exists": False,
                "error": str(exc),
                "stale": True,
            }
        age_seconds = max(0, int(time.time() - stat.st_mtime))
        return {
            "path": str(graph_path),
            "storageKind": storage_kind,
            "storage_kind": storage_kind,
            "project_id": self.project_id(project_root),
            "exists": True,
            "age_seconds": age_seconds,
            "stale": age_seconds > GRAPH_STALE_SECONDS,
            "node_count": node_count,
            "edge_count": edge_count,
            "report_exists": (graph_path.parent / "GRAPH_REPORT.md").exists(),
        }

    def _selected_graph_path(self, project_root: Path | None) -> Path | None:
        managed = [path for path in self.managed_graph_candidates(project_root) if path.exists()]
        legacy = [
            path / "graph.json" for path in self.legacy_graph_dirs(project_root) if (path / "graph.json").exists()
        ]
        graphs = dedupe_paths(managed + legacy)
        return graphs[0] if graphs else None

    def _diagnostics_from_cache(self, graph_path: Path | None) -> dict[str, Any]:
        if graph_path is None:
            return {}
        diagnostics_path = graph_path.parent / "GRAPH_DIAGNOSE.json"
        if not diagnostics_path.exists():
            return {}
        try:
            payload = json.loads(diagnostics_path.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            return {}
        summary = payload.get("summary") if isinstance(payload, dict) else {}
        degraded, reason = diagnostic_degraded_reason(summary if isinstance(summary, dict) else {})
        return {"degraded": degraded, "reason": reason, "path": str(diagnostics_path)}

    def _skip_refresh_reason(self, project_root: Path) -> str | None:
        if not project_root.exists() or not project_root.is_dir():
            return "Project root is missing."
        normalized = str(project_root)
        if normalized.startswith("/private/tmp/") or normalized.startswith("/tmp/"):
            return "Temporary fixture project skipped."
        return None

    def _run_graph_report_command(self, cmd: list[str], output: Path, root: Path | None) -> dict[str, Any]:
        try:
            result = subprocess.run(
                cmd, cwd=str(root) if root else None, capture_output=True, text=True, timeout=90, check=False
            )
        except Exception as exc:
            return {"status": "error", "summary": str(exc), "outputPath": str(output), "output_path": str(output)}
        if result.returncode != 0:
            summary = (result.stderr or result.stdout or "Graphify report command failed.").strip()[:1000]
            return {"status": "error", "summary": summary, "outputPath": str(output), "output_path": str(output)}
        return {
            "status": "ok",
            "summary": (result.stdout or "Graphify report generated.").strip()[:1000],
            "outputPath": str(output),
            "output_path": str(output),
        }

    def _recommended_action(
        self,
        storage_kind: str,
        stale: bool,
        *,
        degraded: bool = False,
        graph_version: str | None = None,
        tool_version: str | None = None,
    ) -> str | None:
        if not tool_version:
            return "Install Graphify tool."
        if degraded:
            return "Rebuild managed graph; diagnostics marked the graph degraded."
        if storage_kind == "missing":
            return "Build managed graph when graph hints would help this project."
        if storage_kind == "legacy":
            return "Move to Soma storage."
        if graph_version and tool_version and version_tuple(graph_version) < version_tuple(tool_version):
            return "Refresh managed graph."
        if stale:
            return "Update managed graph."
        return None

    def _run_semantic_check(self, root: Path, source_root: Path) -> subprocess.CompletedProcess | dict[str, Any]:
        env = {"GRAPHIFY_OUT": str(self.graph_dir(root)), **__import__("os").environ.copy()}
        try:
            return subprocess.run(
                [self._graphify_bin(), "check-update", str(source_root)],
                cwd=str(root),
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
        except Exception as exc:
            return {"status": "error", "summary": str(exc), "pending": None}

    def _run_diagnostics(self, graph_path: Path) -> subprocess.CompletedProcess | dict[str, Any]:
        try:
            result = subprocess.run(
                [self._graphify_bin(), "diagnose", "multigraph", "--json", "--graph", str(graph_path)],
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )
        except Exception as exc:
            return {"status": "error", "summary": str(exc), "degraded": True, "reason": str(exc)}
        if result.returncode != 0:
            reason = (result.stderr or result.stdout or "Graph diagnostics failed.").strip()[:1000]
            return {"status": "error", "summary": reason, "degraded": True, "reason": reason}
        return result

    def _diagnostics_payload(
        self, summary: dict[str, Any], diagnostics_path: Path, degraded: bool, reason: str | None
    ) -> dict[str, Any]:
        same_endpoint = max(
            int(summary.get("directed_same_endpoint_collapsed_edges") or 0),
            int(summary.get("undirected_same_endpoint_collapsed_edges") or 0),
        )
        return {
            "status": "ok",
            "summary": reason or "Graph diagnostics passed.",
            "degraded": degraded,
            "reason": reason,
            "path": str(diagnostics_path),
            "nodeCount": summary.get("node_count"),
            "node_count": summary.get("node_count"),
            "edgeCount": summary.get("raw_edge_count"),
            "edge_count": summary.get("raw_edge_count"),
            "sameEndpointCollapsedEdges": same_endpoint,
            "same_endpoint_collapsed_edges": same_endpoint,
        }

    def _write_diagnostics(self, path: Path, payload: dict[str, Any]) -> None:
        try:
            path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
        except Exception:
            pass

    def _report_root_and_graph(self, project_root: str | Path | None) -> tuple[Path | None, Path | None]:
        root = self.normalize_project_root(project_root)
        return root, self._selected_graph_path(root)

    def _graph_last_updated(self, selected_path: str | None, existing: dict[str, Any]) -> int | None:
        if not selected_path:
            return existing.get("lastUpdated") if isinstance(existing, dict) else None
        try:
            return int(Path(selected_path).joinpath("graph.json").stat().st_mtime)
        except OSError:
            return existing.get("lastUpdated") if isinstance(existing, dict) else None

    def _graphify_bin(self) -> str:
        return shutil.which("graphify") or str(Path.home() / ".local" / "bin" / "graphify")

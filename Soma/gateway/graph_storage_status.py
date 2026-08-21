from __future__ import annotations

from pathlib import Path
from typing import Any

from .graph_storage_utils import dedupe_paths


class GraphStorageStatusMixin:
    def status(self, project_root: str | Path | None) -> dict[str, Any]:
        root = self.normalize_project_root(project_root)
        context = self._status_context(root)
        status = self._status_payload(root, context)
        if root:
            self.update_index(root, status)
        return status

    def _status_context(self, root: Path | None) -> dict[str, Any]:
        managed_graphs = [path for path in self.managed_graph_candidates(root) if path.exists()]
        legacy_graphs = [path / "graph.json" for path in self.legacy_graph_dirs(root) if (path / "graph.json").exists()]
        graphs = dedupe_paths(managed_graphs + legacy_graphs)
        selected = graphs[0] if graphs else None
        diagnostics = self._diagnostics_from_cache(selected)
        index_entry = self._index_entry(root)
        tool_version = self.graphify_version()
        graph_version = index_entry.get("graphifyVersion") if isinstance(index_entry, dict) else None
        stale = self._status_stale(graphs, managed_graphs, legacy_graphs, root)
        return {
            "managed_graphs": managed_graphs,
            "legacy_graphs": legacy_graphs,
            "graphs": graphs,
            "selected": selected,
            "diagnostics": diagnostics,
            "degraded": bool(diagnostics.get("degraded")) if diagnostics else False,
            "graph_version": graph_version,
            "tool_version": tool_version,
            "stale": stale,
            "source_root": self.graph_source_root(root),
        }

    def _status_stale(
        self, graphs: list[Path], managed_graphs: list[Path], legacy_graphs: list[Path], root: Path | None
    ) -> bool:
        entries = [
            self._graph_entry(path, root, "managed" if path in managed_graphs else "legacy") for path in graphs[:8]
        ]
        return any(entry.get("stale") for entry in entries) if entries else True

    def _status_payload(self, root: Path | None, context: dict[str, Any]) -> dict[str, Any]:
        managed_graphs = context["managed_graphs"]
        legacy_graphs = context["legacy_graphs"]
        graphs = context["graphs"]
        selected = context["selected"]
        storage_kind = "managed" if managed_graphs else ("legacy" if legacy_graphs else "missing")
        node_count, edge_count = self.count_graph(selected) if selected else (None, None)
        entries = [
            self._graph_entry(path, root, "managed" if path in managed_graphs else "legacy") for path in graphs[:8]
        ]
        diagnostics = context["diagnostics"]
        return {
            **self._availability_fields(graphs, managed_graphs, legacy_graphs, storage_kind),
            "stale": context["stale"],
            "nodeCount": node_count,
            "node_count": node_count,
            "edgeCount": edge_count,
            "edge_count": edge_count,
            "storagePath": str(selected.parent) if selected else None,
            "storage_path": str(selected.parent) if selected else None,
            "managedPath": str(managed_graphs[0].parent) if managed_graphs else None,
            "managed_path": str(managed_graphs[0].parent) if managed_graphs else None,
            "legacyPaths": [str(path.parent) for path in legacy_graphs],
            "legacy_paths": [str(path.parent) for path in legacy_graphs],
            "graphs": entries,
            **self._version_fields(context),
            **self._diagnostic_fields(diagnostics, context["degraded"]),
            **self._source_fields(root, context["source_root"]),
            "recommendedAction": self._status_action(storage_kind, context),
            "recommended_action": self._status_action(storage_kind, context),
        }

    def _availability_fields(self, graphs, managed_graphs, legacy_graphs, storage_kind):
        return {
            "available": bool(graphs),
            "project_graph_available": bool(graphs),
            "managedAvailable": bool(managed_graphs),
            "managed_available": bool(managed_graphs),
            "legacyAvailable": bool(legacy_graphs),
            "legacy_available": bool(legacy_graphs),
            "storageKind": storage_kind,
            "storage_kind": storage_kind,
        }

    def _version_fields(self, context: dict[str, Any]) -> dict[str, Any]:
        return {
            "graphifyVersion": context["graph_version"],
            "graphify_version": context["graph_version"],
            "toolVersion": context["tool_version"],
            "tool_version": context["tool_version"],
        }

    def _diagnostic_fields(self, diagnostics: dict[str, Any], degraded: bool) -> dict[str, Any]:
        return {
            "graphDegraded": degraded,
            "graph_degraded": degraded,
            "graphDegradedReason": diagnostics.get("reason") if diagnostics else None,
            "graph_degraded_reason": diagnostics.get("reason") if diagnostics else None,
            "diagnosticsPath": diagnostics.get("path") if diagnostics else None,
            "diagnostics_path": diagnostics.get("path") if diagnostics else None,
        }

    def _source_fields(self, root: Path | None, source_root: Path | None) -> dict[str, Any]:
        return {
            "graphSourceRoot": str(source_root) if source_root else None,
            "graph_source_root": str(source_root) if source_root else None,
            "graphScope": self.graph_scope(root),
            "graph_scope": self.graph_scope(root),
        }

    def _status_action(self, storage_kind: str, context: dict[str, Any]) -> str | None:
        return self._recommended_action(
            storage_kind,
            context["stale"],
            degraded=context["degraded"],
            graph_version=context["graph_version"],
            tool_version=context["tool_version"],
        )

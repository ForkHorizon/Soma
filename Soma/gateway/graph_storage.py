from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any

GRAPHIFY_BASE_DIR = Path.home() / ".soma" / "graphs"
GRAPH_STALE_SECONDS = 24 * 60 * 60


class GraphStorageManager:
    def __init__(self, base_dir: Path | str = GRAPHIFY_BASE_DIR):
        self.base_dir = Path(base_dir).expanduser()
        self.projects_dir = self.base_dir / "projects"
        self.index_path = self.base_dir / "index.json"

    def normalize_project_root(self, project_root: str | Path | None) -> Path | None:
        if not project_root:
            return None
        return Path(project_root).expanduser().resolve(strict=False)

    def project_id(self, project_root: str | Path | None) -> str:
        root = self.normalize_project_root(project_root)
        if root is None:
            return "default"
        return hashlib.sha256(str(root).encode("utf-8")).hexdigest()[:16]

    def project_dir(self, project_root: str | Path | None) -> Path:
        return self.projects_dir / self.project_id(project_root)

    def graph_dir(self, project_root: str | Path | None) -> Path:
        return self.project_dir(project_root) / "graphify-out"

    def graph_json(self, project_root: str | Path | None) -> Path:
        return self.graph_dir(project_root) / "graph.json"

    def alternate_managed_graph_json(self, project_root: str | Path | None) -> Path:
        return self.project_dir(project_root) / "graph.json"

    def legacy_graph_dirs(self, project_root: str | Path | None) -> list[Path]:
        root = self.normalize_project_root(project_root)
        if root is None:
            return []
        candidates = [
            root / "graphify-out",
            root / ".soma" / "graphify-out",
            root / "Assets" / "graphify-out",
            root / "Assets" / "NexusUnity" / "graphify-out",
        ]
        for parent_name in ("Assets", "Packages"):
            parent = root / parent_name
            if not parent.is_dir():
                continue
            try:
                for child in parent.iterdir():
                    if child.name.startswith("."):
                        continue
                    candidates.append(child / "graphify-out")
            except OSError:
                continue
        return _dedupe_paths(candidates)

    def managed_graph_candidates(self, project_root: str | Path | None) -> list[Path]:
        return _dedupe_paths([self.graph_json(project_root), self.alternate_managed_graph_json(project_root)])

    def graphify_version(self) -> str | None:
        try:
            result = subprocess.run(
                ["graphify", "--version"],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        except Exception:
            return None
        output = (result.stdout or result.stderr or "").strip()
        if not output:
            return None
        return output.splitlines()[-1].strip().split()[-1]

    def count_graph(self, graph_path: Path) -> tuple[int | None, int | None]:
        try:
            data = json.loads(graph_path.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            return None, None
        if not isinstance(data, dict):
            return None, None
        nodes = data.get("nodes")
        edges = data.get("edges")
        links = data.get("links")
        node_count = len(nodes) if isinstance(nodes, list) else None
        edge_source = edges if isinstance(edges, list) else links
        edge_count = len(edge_source) if isinstance(edge_source, list) else None
        return node_count, edge_count

    def read_index(self) -> dict[str, Any]:
        try:
            data = json.loads(self.index_path.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            return {"projects": {}}
        if not isinstance(data, dict):
            return {"projects": {}}
        if not isinstance(data.get("projects"), dict):
            data["projects"] = {}
        return data

    def write_index(self, data: dict[str, Any]) -> None:
        self.base_dir.mkdir(parents=True, exist_ok=True)
        tmp_path = self.index_path.with_suffix(".json.tmp")
        tmp_path.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
        tmp_path.replace(self.index_path)

    def storage_info(self, project_root: str | Path | None) -> dict[str, Any]:
        root = self.normalize_project_root(project_root)
        pid = self.project_id(root)
        project_dir = self.project_dir(root)
        graph_dir = self.graph_dir(root)
        legacy_paths = [str(path) for path in self.legacy_graph_dirs(root) if (path / "graph.json").exists()]
        return {
            "project_id": pid,
            "projectRoot": str(root) if root else None,
            "project_root": str(root) if root else None,
            "displayName": root.name if root else "Default",
            "display_name": root.name if root else "Default",
            "projectDir": str(project_dir),
            "project_dir": str(project_dir),
            "outputRoot": str(project_dir),
            "output_root": str(project_dir),
            "graphDir": str(graph_dir),
            "graph_dir": str(graph_dir),
            "graphJson": str(graph_dir / "graph.json"),
            "graph_json": str(graph_dir / "graph.json"),
            "legacyPaths": legacy_paths,
            "legacy_paths": legacy_paths,
        }

    def status(self, project_root: str | Path | None) -> dict[str, Any]:
        root = self.normalize_project_root(project_root)
        managed_graphs = [path for path in self.managed_graph_candidates(root) if path.exists()]
        legacy_graphs = [path / "graph.json" for path in self.legacy_graph_dirs(root) if (path / "graph.json").exists()]
        graphs = _dedupe_paths(managed_graphs + legacy_graphs)
        selected = graphs[0] if graphs else None
        storage_kind = "managed" if managed_graphs else ("legacy" if legacy_graphs else "missing")
        entries = [self._graph_entry(path, root, "managed" if path in managed_graphs else "legacy") for path in graphs[:8]]
        stale = any(entry.get("stale") for entry in entries) if entries else True
        node_count = edge_count = None
        storage_path = managed_path = None
        if selected:
            node_count, edge_count = self.count_graph(selected)
            storage_path = str(selected.parent)
        if managed_graphs:
            managed_path = str(managed_graphs[0].parent)
        recommended_action = self._recommended_action(storage_kind, stale)
        graphify_version = self.graphify_version()
        status = {
            "available": bool(graphs),
            "project_graph_available": bool(graphs),
            "managedAvailable": bool(managed_graphs),
            "managed_available": bool(managed_graphs),
            "legacyAvailable": bool(legacy_graphs),
            "legacy_available": bool(legacy_graphs),
            "storageKind": storage_kind,
            "storage_kind": storage_kind,
            "stale": stale,
            "nodeCount": node_count,
            "node_count": node_count,
            "edgeCount": edge_count,
            "edge_count": edge_count,
            "storagePath": storage_path,
            "storage_path": storage_path,
            "managedPath": managed_path,
            "managed_path": managed_path,
            "legacyPaths": [str(path.parent) for path in legacy_graphs],
            "legacy_paths": [str(path.parent) for path in legacy_graphs],
            "graphs": entries,
            "graphifyVersion": graphify_version,
            "graphify_version": graphify_version,
            "recommendedAction": recommended_action,
            "recommended_action": recommended_action,
        }
        if root:
            self.update_index(root, status)
        return status

    def migrate_graph(self, project_root: str | Path | None) -> dict[str, Any]:
        root = self.normalize_project_root(project_root)
        if root is None:
            return {"status": "error", "summary": "project_root is required", "graph": self.status(root)}
        legacy_dirs = [path for path in self.legacy_graph_dirs(root) if (path / "graph.json").exists()]
        if not legacy_dirs:
            return {"status": "skipped", "summary": "No legacy graphify-out found.", "graph": self.status(root)}
        source = legacy_dirs[0]
        target = self.graph_dir(root)
        if source.resolve(strict=False) != target.resolve(strict=False):
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(source, target, dirs_exist_ok=True)
        graph_status = self.status(root)
        return {
            "status": "ok",
            "summary": "Copied legacy graphify-out into Soma managed storage.",
            "source": str(source),
            "target": str(target),
            "legacy_retained": True,
            "graph": graph_status,
        }

    def update_index(self, project_root: Path, status: dict[str, Any]) -> None:
        pid = self.project_id(project_root)
        data = self.read_index()
        data["projects"][pid] = {
            "projectRoot": str(project_root),
            "displayName": project_root.name,
            "graphifyVersion": status.get("graphifyVersion") or status.get("graphify_version"),
            "lastUpdated": int(time.time()),
            "nodeCount": status.get("nodeCount") or status.get("node_count"),
            "edgeCount": status.get("edgeCount") or status.get("edge_count"),
            "storagePath": status.get("storagePath") or status.get("storage_path"),
            "legacyPaths": status.get("legacyPaths") or status.get("legacy_paths") or [],
        }
        try:
            self.write_index(data)
        except Exception:
            pass

    def _graph_entry(self, graph_path: Path, project_root: Path | None, storage_kind: str) -> dict[str, Any]:
        try:
            stat = graph_path.stat()
            age_seconds = max(0, int(time.time() - stat.st_mtime))
            node_count, edge_count = self.count_graph(graph_path)
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
        except OSError as exc:
            return {"path": str(graph_path), "storageKind": storage_kind, "exists": False, "error": str(exc), "stale": True}

    def _recommended_action(self, storage_kind: str, stale: bool) -> str | None:
        if storage_kind == "missing":
            return "Build managed graph when graph hints would help this project."
        if storage_kind == "legacy":
            return "Move to Soma storage."
        if stale:
            return "Update managed graph."
        return None


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

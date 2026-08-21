from __future__ import annotations

import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

from .graph_storage_utils import GRAPHIFY_BASE_DIR, dedupe_paths, version_tuple


class GraphStoragePathsMixin:
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

    def is_unity_project(self, project_root: str | Path | None) -> bool:
        root = self.normalize_project_root(project_root)
        if root is None:
            return False
        return (root / "Assets").is_dir() and (
            (root / "ProjectSettings").is_dir() or (root / "Packages" / "manifest.json").is_file()
        )

    def graph_source_root(self, project_root: str | Path | None) -> Path | None:
        root = self.normalize_project_root(project_root)
        if root is None:
            return None
        assets = root / "Assets"
        if self.is_unity_project(root) and assets.is_dir():
            return assets.resolve(strict=False)
        return root

    def graph_scope(self, project_root: str | Path | None) -> str:
        return "unity_assets" if self.is_unity_project(project_root) else "project_root"

    def legacy_graph_dirs(self, project_root: str | Path | None) -> list[Path]:
        root = self.normalize_project_root(project_root)
        if root is None:
            return []
        candidates = self._fixed_legacy_graph_dirs(root) + self._package_legacy_graph_dirs(root)
        return dedupe_paths(candidates)

    def managed_graph_candidates(self, project_root: str | Path | None) -> list[Path]:
        return dedupe_paths([self.graph_json(project_root), self.alternate_managed_graph_json(project_root)])

    def graphify_version(self) -> str | None:
        graphify_bin = shutil.which("graphify") or str(Path.home() / ".local" / "bin" / "graphify")
        try:
            result = subprocess.run([graphify_bin, "--version"], capture_output=True, text=True, timeout=5, check=False)
        except Exception:
            return None
        output = (result.stdout or result.stderr or "").strip()
        return output.splitlines()[-1].strip().split()[-1] if output else None

    def latest_graphify_version(self) -> str | None:
        try:
            result = subprocess.run(
                [sys.executable, "-m", "pip", "index", "versions", "graphifyy"],
                capture_output=True,
                text=True,
                timeout=12,
                check=False,
            )
        except Exception:
            return None
        match = re.search(
            r"graphifyy\s+\(([^)]+)\)", "\n".join(part for part in (result.stdout, result.stderr) if part)
        )
        return match.group(1).strip() if match else None

    def tool_version_status(self, check_latest: bool = True) -> dict[str, Any]:
        installed = self.graphify_version()
        latest = self.latest_graphify_version() if check_latest else None
        up_to_date = version_tuple(installed) >= version_tuple(latest) if installed and latest else None
        action = None
        if installed and latest and not up_to_date:
            action = "upgrade_tool"
        elif not installed:
            action = "install_tool"
        return {
            "status": "ok" if installed else "missing",
            "installedVersion": installed,
            "installed_version": installed,
            "latestVersion": latest,
            "latest_version": latest,
            "upToDate": up_to_date,
            "up_to_date": up_to_date,
            "recommendedAction": action,
            "recommended_action": action,
        }

    def count_graph(self, graph_path: Path) -> tuple[int | None, int | None]:
        try:
            data = json.loads(graph_path.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            return None, None
        nodes = data.get("nodes") if isinstance(data, dict) else None
        edges = data.get("edges") if isinstance(data, dict) else None
        links = data.get("links") if isinstance(data, dict) else None
        edge_source = edges if isinstance(edges, list) else links
        return len(nodes) if isinstance(nodes, list) else None, len(edge_source) if isinstance(
            edge_source, list
        ) else None

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
        project_dir = self.project_dir(root)
        graph_dir = self.graph_dir(root)
        source_root = self.graph_source_root(root)
        legacy_paths = [str(path) for path in self.legacy_graph_dirs(root) if (path / "graph.json").exists()]
        return {
            "project_id": self.project_id(root),
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
            "graphSourceRoot": str(source_root) if source_root else None,
            "graph_source_root": str(source_root) if source_root else None,
            "graphScope": self.graph_scope(root),
            "graph_scope": self.graph_scope(root),
            "legacyPaths": legacy_paths,
            "legacy_paths": legacy_paths,
        }

    def _fixed_legacy_graph_dirs(self, root: Path) -> list[Path]:
        return [
            root / "graphify-out",
            root / ".soma" / "graphify-out",
            root / "Assets" / "graphify-out",
            root / "Assets" / "NexusUnity" / "graphify-out",
        ]

    def _package_legacy_graph_dirs(self, root: Path) -> list[Path]:
        candidates: list[Path] = []
        for parent_name in ("Assets", "Packages"):
            parent = root / parent_name
            if not parent.is_dir():
                continue
            try:
                candidates.extend(
                    child / "graphify-out" for child in parent.iterdir() if not child.name.startswith(".")
                )
            except OSError:
                continue
        return candidates

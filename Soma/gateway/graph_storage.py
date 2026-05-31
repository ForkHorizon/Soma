from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
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

    def is_unity_project(self, project_root: str | Path | None) -> bool:
        root = self.normalize_project_root(project_root)
        if root is None:
            return False
        return (
            (root / "Assets").is_dir()
            and (
                (root / "ProjectSettings").is_dir()
                or (root / "Packages" / "manifest.json").is_file()
            )
        )

    def graph_source_root(self, project_root: str | Path | None) -> Path | None:
        root = self.normalize_project_root(project_root)
        if root is None:
            return None
        if self.is_unity_project(root):
            assets = root / "Assets"
            if assets.is_dir():
                return assets.resolve(strict=False)
        return root

    def graph_scope(self, project_root: str | Path | None) -> str:
        return "unity_assets" if self.is_unity_project(project_root) else "project_root"

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
        graphify_bin = shutil.which("graphify") or str(Path.home() / ".local" / "bin" / "graphify")
        try:
            result = subprocess.run(
                [graphify_bin, "--version"],
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
        output = "\n".join(part for part in (result.stdout, result.stderr) if part)
        match = re.search(r"graphifyy\s+\(([^)]+)\)", output)
        return match.group(1).strip() if match else None

    def tool_version_status(self, check_latest: bool = True) -> dict[str, Any]:
        installed = self.graphify_version()
        latest = self.latest_graphify_version() if check_latest else None
        up_to_date = None
        recommended_action = None
        if installed and latest:
            up_to_date = _version_tuple(installed) >= _version_tuple(latest)
            if not up_to_date:
                recommended_action = "upgrade_tool"
        elif not installed:
            recommended_action = "install_tool"
        return {
            "status": "ok" if installed else "missing",
            "installedVersion": installed,
            "installed_version": installed,
            "latestVersion": latest,
            "latest_version": latest,
            "upToDate": up_to_date,
            "up_to_date": up_to_date,
            "recommendedAction": recommended_action,
            "recommended_action": recommended_action,
        }

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
        graph_source_root = self.graph_source_root(root)
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
            "graphSourceRoot": str(graph_source_root) if graph_source_root else None,
            "graph_source_root": str(graph_source_root) if graph_source_root else None,
            "graphScope": self.graph_scope(root),
            "graph_scope": self.graph_scope(root),
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
        installed_version = self.graphify_version()
        index_entry = self._index_entry(root)
        graph_source_root = self.graph_source_root(root)
        graph_build_version = index_entry.get("graphifyVersion") if isinstance(index_entry, dict) else None
        diagnostics = self._diagnostics_from_cache(selected)
        degraded = bool(diagnostics.get("degraded")) if diagnostics else False
        recommended_action = self._recommended_action(
            storage_kind,
            stale,
            degraded=degraded,
            graph_version=graph_build_version,
            tool_version=installed_version,
        )
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
            "graphifyVersion": graph_build_version,
            "graphify_version": graph_build_version,
            "toolVersion": installed_version,
            "tool_version": installed_version,
            "graphDegraded": degraded,
            "graph_degraded": degraded,
            "graphDegradedReason": diagnostics.get("reason") if diagnostics else None,
            "graph_degraded_reason": diagnostics.get("reason") if diagnostics else None,
            "diagnosticsPath": diagnostics.get("path") if diagnostics else None,
            "diagnostics_path": diagnostics.get("path") if diagnostics else None,
            "graphSourceRoot": str(graph_source_root) if graph_source_root else None,
            "graph_source_root": str(graph_source_root) if graph_source_root else None,
            "graphScope": self.graph_scope(root),
            "graph_scope": self.graph_scope(root),
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
        self.update_index(root, graph_status, graphify_version=self.graphify_version())
        graph_status = self.status(root)
        return {
            "status": "ok",
            "summary": "Copied legacy graphify-out into Soma managed storage.",
            "source": str(source),
            "target": str(target),
            "legacy_retained": True,
            "graph": graph_status,
        }

    def refresh_managed_graph(self, project_root: str | Path | None, *, full: bool = False, force: bool = False) -> dict[str, Any]:
        root = self.normalize_project_root(project_root)
        if root is None:
            return {"status": "error", "summary": "project_root is required", "graph": self.status(root)}
        skip_reason = self._skip_refresh_reason(root)
        if skip_reason:
            return {"status": "skipped", "summary": skip_reason, "projectRoot": str(root), "graph": self.status(root)}

        managed_graph = self.graph_json(root)
        if not managed_graph.exists():
            legacy = [path for path in self.legacy_graph_dirs(root) if (path / "graph.json").exists()]
            if legacy and not full:
                self.migrate_graph(root)
            elif not full:
                return {
                    "status": "skipped",
                    "summary": "No managed graph exists yet. Use full rebuild to create one explicitly.",
                    "projectRoot": str(root),
                    "graph": self.status(root),
                }

        self.graph_dir(root).mkdir(parents=True, exist_ok=True)
        graph_source_root = self.graph_source_root(root)
        if graph_source_root is None:
            return {"status": "error", "summary": "Graph source root is unavailable.", "projectRoot": str(root), "graph": self.status(root)}
        if not graph_source_root.exists() or not graph_source_root.is_dir():
            return {
                "status": "skipped",
                "summary": f"Graph source root is missing: {graph_source_root}",
                "projectRoot": str(root),
                "graphSourceRoot": str(graph_source_root),
                "graph": self.status(root),
            }
        graphify_bin = shutil.which("graphify") or str(Path.home() / ".local" / "bin" / "graphify")
        env = os.environ.copy()
        env["GRAPHIFY_OUT"] = str(self.graph_dir(root))
        env["GRAPHIFY_NO_TIPS"] = "1"
        before_project_graph_exists = (root / "graphify-out").exists()
        before_source_graph_exists = (graph_source_root / "graphify-out").exists()
        if full:
            cmd = [graphify_bin, "extract", str(graph_source_root), "--out", str(self.project_dir(root))]
            timeout = 60 * 60
            mode = "full_rebuild"
        else:
            cmd = [graphify_bin, "update"]
            if force or self.graph_scope(root) == "unity_assets":
                cmd.append("--force")
            cmd.append(str(graph_source_root))
            timeout = 10 * 60
            mode = "ast_update"

        try:
            result = subprocess.run(
                cmd,
                cwd=str(root),
                env=env,
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
        except Exception as exc:
            return {"status": "error", "summary": str(exc), "mode": mode, "projectRoot": str(root), "graph": self.status(root)}

        if result.returncode != 0:
            return {
                "status": "error",
                "summary": (result.stderr or result.stdout or "Graphify refresh failed.").strip()[:1000],
                "mode": mode,
                "projectRoot": str(root),
                "graphSourceRoot": str(graph_source_root),
                "stdout": (result.stdout or "").strip()[:2000],
                "stderr": (result.stderr or "").strip()[:2000],
                "graph": self.status(root),
            }

        diagnostics = self.diagnose_graph(root)
        graph_status = self.status(root)
        self.update_index(root, graph_status, graphify_version=self.graphify_version())
        graph_status = self.status(root)
        project_root_polluted = not before_project_graph_exists and (root / "graphify-out").exists()
        source_root_polluted = not before_source_graph_exists and (graph_source_root / "graphify-out").exists()
        warnings = []
        if project_root_polluted:
            warnings.append("A project-root graphify-out appeared during refresh.")
        if source_root_polluted and graph_source_root.resolve(strict=False) != root.resolve(strict=False):
            warnings.append("A graphify-out appeared under the graph source root during refresh.")
        if diagnostics.get("degraded"):
            warnings.append(diagnostics.get("reason") or "Graph diagnostics marked this graph degraded.")
        return {
            "status": "ok",
            "summary": "Managed Graphify graph refreshed." if not full else "Managed Graphify graph rebuilt.",
            "mode": mode,
            "projectRoot": str(root),
            "graphSourceRoot": str(graph_source_root),
            "graphScope": self.graph_scope(root),
            "stdout": (result.stdout or "").strip()[:2000],
            "stderr": (result.stderr or "").strip()[:2000],
            "diagnostics": diagnostics,
            "warnings": warnings,
            "graph": graph_status,
        }

    def refresh_all_managed_graphs(self, *, full: bool = False) -> dict[str, Any]:
        data = self.read_index()
        results = []
        for entry in list((data.get("projects") or {}).values()):
            root = entry.get("projectRoot") if isinstance(entry, dict) else None
            if not root:
                continue
            normalized = self.normalize_project_root(root)
            if normalized is None:
                continue
            skip_reason = self._skip_refresh_reason(normalized)
            if skip_reason:
                results.append({"status": "skipped", "projectRoot": str(normalized), "summary": skip_reason})
                continue
            if not self.graph_json(normalized).exists() and not full:
                results.append({"status": "skipped", "projectRoot": str(normalized), "summary": "No managed graph to refresh."})
                continue
            results.append(self.refresh_managed_graph(normalized, full=full))
        return {
            "status": "ok",
            "summary": f"Processed {len(results)} indexed project graph(s).",
            "processed": len(results),
            "refreshed": len([item for item in results if item.get("status") == "ok"]),
            "skipped": len([item for item in results if item.get("status") == "skipped"]),
            "failed": len([item for item in results if item.get("status") == "error"]),
            "results": results,
        }

    def check_semantic_update(self, project_root: str | Path | None) -> dict[str, Any]:
        root = self.normalize_project_root(project_root)
        if root is None:
            return {"status": "error", "summary": "project_root is required"}
        graph_source_root = self.graph_source_root(root)
        if graph_source_root is None:
            return {"status": "error", "summary": "Graph source root is unavailable.", "pending": None}
        graph_path = self.graph_json(root)
        if not graph_path.exists():
            return {"status": "skipped", "summary": "No managed graph found.", "pending": False}
        graphify_bin = shutil.which("graphify") or str(Path.home() / ".local" / "bin" / "graphify")
        env = os.environ.copy()
        env["GRAPHIFY_OUT"] = str(self.graph_dir(root))
        try:
            result = subprocess.run(
                [graphify_bin, "check-update", str(graph_source_root)],
                cwd=str(root),
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
        except Exception as exc:
            return {"status": "error", "summary": str(exc), "pending": None}
        output = "\n".join(part.strip() for part in (result.stdout, result.stderr) if part.strip())
        pending = bool(re.search(r"\b(needs?_update|pending|semantic)\b", output, re.IGNORECASE))
        return {
            "status": "ok" if result.returncode == 0 else "error",
            "summary": output[:1000] if output else "No semantic refresh pending.",
            "pending": pending,
            "returncode": result.returncode,
            "graphSourceRoot": str(graph_source_root),
            "graph_source_root": str(graph_source_root),
        }

    def diagnose_graph(self, project_root: str | Path | None) -> dict[str, Any]:
        root = self.normalize_project_root(project_root)
        graph_path = self._selected_graph_path(root)
        if graph_path is None:
            return {"status": "skipped", "summary": "No project graph found.", "degraded": False}
        graphify_bin = shutil.which("graphify") or str(Path.home() / ".local" / "bin" / "graphify")
        try:
            result = subprocess.run(
                [graphify_bin, "diagnose", "multigraph", "--json", "--graph", str(graph_path)],
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
        try:
            payload = json.loads(result.stdout)
        except Exception as exc:
            return {"status": "error", "summary": f"Diagnostics JSON unreadable: {exc}", "degraded": True, "reason": str(exc)}
        summary = payload.get("summary") if isinstance(payload, dict) else {}
        degraded, reason = _diagnostic_degraded_reason(summary if isinstance(summary, dict) else {})
        diagnostics_path = graph_path.parent / "GRAPH_DIAGNOSE.json"
        try:
            diagnostics_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
        except Exception:
            pass
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
            "sameEndpointCollapsedEdges": max(
                int(summary.get("directed_same_endpoint_collapsed_edges") or 0),
                int(summary.get("undirected_same_endpoint_collapsed_edges") or 0),
            ),
            "same_endpoint_collapsed_edges": max(
                int(summary.get("directed_same_endpoint_collapsed_edges") or 0),
                int(summary.get("undirected_same_endpoint_collapsed_edges") or 0),
            ),
        }

    def generate_tree_report(self, project_root: str | Path | None) -> dict[str, Any]:
        root = self.normalize_project_root(project_root)
        graph_path = self._selected_graph_path(root)
        if graph_path is None:
            return {"status": "error", "summary": "No project graph found."}
        graph_source_root = self.graph_source_root(root)
        output = graph_path.parent / "GRAPH_TREE.html"
        return self._run_graph_report_command(
            [shutil.which("graphify") or str(Path.home() / ".local" / "bin" / "graphify"), "tree", "--graph", str(graph_path), "--output", str(output), "--root", str(graph_source_root or root), "--label", root.name if root else "Project"],
            output,
            root,
        )

    def generate_callflow_report(self, project_root: str | Path | None) -> dict[str, Any]:
        root = self.normalize_project_root(project_root)
        graph_path = self._selected_graph_path(root)
        if graph_path is None:
            return {"status": "error", "summary": "No project graph found."}
        name = re.sub(r"[^A-Za-z0-9_.-]+", "-", root.name if root else "project").strip("-") or "project"
        output = graph_path.parent / f"{name}-callflow.html"
        return self._run_graph_report_command(
            [shutil.which("graphify") or str(Path.home() / ".local" / "bin" / "graphify"), "export", "callflow-html", "--graph", str(graph_path), "--output", str(output)],
            output,
            root,
        )

    def update_index(self, project_root: Path, status: dict[str, Any], graphify_version: str | None = None) -> None:
        pid = self.project_id(project_root)
        data = self.read_index()
        existing = data["projects"].get(pid, {})
        selected_path = status.get("storagePath") or status.get("storage_path")
        last_updated = None
        if selected_path:
            try:
                last_updated = int(Path(selected_path).joinpath("graph.json").stat().st_mtime)
            except OSError:
                last_updated = existing.get("lastUpdated") if isinstance(existing, dict) else None
        data["projects"][pid] = {
            "projectRoot": str(project_root),
            "displayName": project_root.name,
            "graphSourceRoot": status.get("graphSourceRoot") or status.get("graph_source_root") or (existing.get("graphSourceRoot") if isinstance(existing, dict) else None),
            "graphScope": status.get("graphScope") or status.get("graph_scope") or self.graph_scope(project_root),
            "graphifyVersion": graphify_version or status.get("graphifyVersion") or status.get("graphify_version") or (existing.get("graphifyVersion") if isinstance(existing, dict) else None),
            "lastUpdated": last_updated or int(time.time()),
            "nodeCount": status.get("nodeCount") or status.get("node_count"),
            "edgeCount": status.get("edgeCount") or status.get("edge_count"),
            "storagePath": status.get("storagePath") or status.get("storage_path"),
            "legacyPaths": status.get("legacyPaths") or status.get("legacy_paths") or [],
        }
        try:
            self.write_index(data)
        except Exception:
            pass

    def _index_entry(self, project_root: Path | None) -> dict[str, Any]:
        if project_root is None:
            return {}
        data = self.read_index()
        entry = data.get("projects", {}).get(self.project_id(project_root), {})
        return entry if isinstance(entry, dict) else {}

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

    def _selected_graph_path(self, project_root: Path | None) -> Path | None:
        managed = [path for path in self.managed_graph_candidates(project_root) if path.exists()]
        legacy = [path / "graph.json" for path in self.legacy_graph_dirs(project_root) if (path / "graph.json").exists()]
        graphs = _dedupe_paths(managed + legacy)
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
        degraded, reason = _diagnostic_degraded_reason(summary if isinstance(summary, dict) else {})
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
                cmd,
                cwd=str(root) if root else None,
                capture_output=True,
                text=True,
                timeout=90,
                check=False,
            )
        except Exception as exc:
            return {"status": "error", "summary": str(exc), "outputPath": str(output), "output_path": str(output)}
        if result.returncode != 0:
            return {
                "status": "error",
                "summary": (result.stderr or result.stdout or "Graphify report command failed.").strip()[:1000],
                "outputPath": str(output),
                "output_path": str(output),
            }
        return {
            "status": "ok",
            "summary": (result.stdout or "Graphify report generated.").strip()[:1000],
            "outputPath": str(output),
            "output_path": str(output),
        }

    def _recommended_action(self, storage_kind: str, stale: bool, *, degraded: bool = False, graph_version: str | None = None, tool_version: str | None = None) -> str | None:
        if not tool_version:
            return "Install Graphify tool."
        if degraded:
            return "Rebuild managed graph; diagnostics marked the graph degraded."
        if storage_kind == "missing":
            return "Build managed graph when graph hints would help this project."
        if storage_kind == "legacy":
            return "Move to Soma storage."
        if graph_version and tool_version and _version_tuple(graph_version) < _version_tuple(tool_version):
            return "Refresh managed graph."
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


def _version_tuple(version: str | None) -> tuple[int, ...]:
    if not version:
        return ()
    return tuple(int(part) for part in re.findall(r"\d+", version)[:4])


def _diagnostic_degraded_reason(summary: dict[str, Any]) -> tuple[bool, str | None]:
    collapsed = max(
        int(summary.get("directed_same_endpoint_collapsed_edges") or 0),
        int(summary.get("undirected_same_endpoint_collapsed_edges") or 0),
    )
    malformed = sum(
        int(summary.get(key) or 0)
        for key in ("non_object_edges", "missing_endpoint_edges", "dangling_endpoint_edges")
    )
    post_build_error = str(summary.get("post_build_error") or "").strip()
    if post_build_error:
        return True, f"post-build graph error: {post_build_error[:160]}"
    if malformed:
        return True, f"{malformed} malformed graph edge(s) found."
    if collapsed:
        return True, f"{collapsed} edge(s) may collapse in non-multigraph consumers."
    return False, None

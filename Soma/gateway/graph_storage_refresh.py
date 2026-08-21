from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path
from typing import Any


class GraphStorageRefreshMixin:
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
        return {
            "status": "ok",
            "summary": "Copied legacy graphify-out into Soma managed storage.",
            "source": str(source),
            "target": str(target),
            "legacy_retained": True,
            "graph": self.status(root),
        }

    def refresh_managed_graph(
        self, project_root: str | Path | None, *, full: bool = False, force: bool = False
    ) -> dict[str, Any]:
        root = self.normalize_project_root(project_root)
        if root is None:
            return {"status": "error", "summary": "project_root is required", "graph": self.status(root)}
        early = self._refresh_early_result(root, full)
        if early:
            return early
        source_root = self.graph_source_root(root)
        source_error = self._source_root_error(root, source_root)
        if source_error:
            return source_error
        command = self._refresh_command(root, source_root, full, force)
        result = self._run_refresh_command(root, command)
        if isinstance(result, dict):
            return result
        completed, before_project_graph, before_source_graph = result
        if completed.returncode != 0:
            return self._refresh_failed_payload(root, source_root, command["mode"], completed)
        return self._refresh_ok_payload(
            root, source_root, command["mode"], completed, before_project_graph, before_source_graph, full
        )

    def refresh_all_managed_graphs(self, *, full: bool = False) -> dict[str, Any]:
        results = []
        for entry in list((self.read_index().get("projects") or {}).values()):
            root = entry.get("projectRoot") if isinstance(entry, dict) else None
            normalized = self.normalize_project_root(root) if root else None
            if normalized is None:
                continue
            skip_reason = self._skip_refresh_reason(normalized)
            if skip_reason:
                results.append({"status": "skipped", "projectRoot": str(normalized), "summary": skip_reason})
            elif not self.graph_json(normalized).exists() and not full:
                results.append(
                    {"status": "skipped", "projectRoot": str(normalized), "summary": "No managed graph to refresh."}
                )
            else:
                results.append(self.refresh_managed_graph(normalized, full=full))
        return self._refresh_all_summary(results)

    def _refresh_early_result(self, root: Path, full: bool) -> dict[str, Any] | None:
        skip_reason = self._skip_refresh_reason(root)
        if skip_reason:
            return {"status": "skipped", "summary": skip_reason, "projectRoot": str(root), "graph": self.status(root)}
        managed_graph = self.graph_json(root)
        if managed_graph.exists() or full:
            return None
        legacy = [path for path in self.legacy_graph_dirs(root) if (path / "graph.json").exists()]
        if legacy:
            self.migrate_graph(root)
            return None
        return {
            "status": "skipped",
            "summary": "No managed graph exists yet. Use full rebuild to create one explicitly.",
            "projectRoot": str(root),
            "graph": self.status(root),
        }

    def _source_root_error(self, root: Path, source_root: Path | None) -> dict[str, Any] | None:
        if source_root is None:
            return {
                "status": "error",
                "summary": "Graph source root is unavailable.",
                "projectRoot": str(root),
                "graph": self.status(root),
            }
        if source_root.exists() and source_root.is_dir():
            return None
        return {
            "status": "skipped",
            "summary": f"Graph source root is missing: {source_root}",
            "projectRoot": str(root),
            "graphSourceRoot": str(source_root),
            "graph": self.status(root),
        }

    def _refresh_command(self, root: Path, source_root: Path, full: bool, force: bool) -> dict[str, Any]:
        graphify_bin = shutil.which("graphify") or str(Path.home() / ".local" / "bin" / "graphify")
        if full:
            return {
                "cmd": [graphify_bin, "extract", str(source_root), "--out", str(self.project_dir(root))],
                "timeout": 60 * 60,
                "mode": "full_rebuild",
            }
        cmd = [graphify_bin, "update"]
        if force or self.graph_scope(root) == "unity_assets":
            cmd.append("--force")
        return {"cmd": cmd + [str(source_root)], "timeout": 10 * 60, "mode": "ast_update"}

    def _run_refresh_command(
        self, root: Path, command: dict[str, Any]
    ) -> tuple[subprocess.CompletedProcess, bool, bool] | dict[str, Any]:
        source_root = self.graph_source_root(root)
        self.graph_dir(root).mkdir(parents=True, exist_ok=True)
        env = os.environ.copy()
        env["GRAPHIFY_OUT"] = str(self.graph_dir(root))
        env["GRAPHIFY_NO_TIPS"] = "1"
        before_project_graph = (root / "graphify-out").exists()
        before_source_graph = (source_root / "graphify-out").exists() if source_root else False
        try:
            completed = subprocess.run(
                command["cmd"],
                cwd=str(root),
                env=env,
                capture_output=True,
                text=True,
                timeout=command["timeout"],
                check=False,
            )
        except Exception as exc:
            return {
                "status": "error",
                "summary": str(exc),
                "mode": command["mode"],
                "projectRoot": str(root),
                "graph": self.status(root),
            }
        return completed, before_project_graph, before_source_graph

    def _refresh_failed_payload(
        self, root: Path, source_root: Path, mode: str, result: subprocess.CompletedProcess
    ) -> dict[str, Any]:
        return {
            "status": "error",
            "summary": (result.stderr or result.stdout or "Graphify refresh failed.").strip()[:1000],
            "mode": mode,
            "projectRoot": str(root),
            "graphSourceRoot": str(source_root),
            "stdout": (result.stdout or "").strip()[:2000],
            "stderr": (result.stderr or "").strip()[:2000],
            "graph": self.status(root),
        }

    def _refresh_ok_payload(
        self,
        root: Path,
        source_root: Path,
        mode: str,
        result: subprocess.CompletedProcess,
        before_project_graph: bool,
        before_source_graph: bool,
        full: bool,
    ) -> dict[str, Any]:
        diagnostics = self.diagnose_graph(root)
        graph_status = self.status(root)
        self.update_index(root, graph_status, graphify_version=self.graphify_version())
        return {
            "status": "ok",
            "summary": "Managed Graphify graph rebuilt." if full else "Managed Graphify graph refreshed.",
            "mode": mode,
            "projectRoot": str(root),
            "graphSourceRoot": str(source_root),
            "graphScope": self.graph_scope(root),
            "stdout": (result.stdout or "").strip()[:2000],
            "stderr": (result.stderr or "").strip()[:2000],
            "diagnostics": diagnostics,
            "warnings": self._refresh_warnings(
                root, source_root, before_project_graph, before_source_graph, diagnostics
            ),
            "graph": self.status(root),
        }

    def _refresh_warnings(
        self,
        root: Path,
        source_root: Path,
        before_project_graph: bool,
        before_source_graph: bool,
        diagnostics: dict[str, Any],
    ) -> list[str]:
        warnings = []
        if not before_project_graph and (root / "graphify-out").exists():
            warnings.append("A project-root graphify-out appeared during refresh.")
        if (
            not before_source_graph
            and (source_root / "graphify-out").exists()
            and source_root.resolve(strict=False) != root.resolve(strict=False)
        ):
            warnings.append("A graphify-out appeared under the graph source root during refresh.")
        if diagnostics.get("degraded"):
            warnings.append(diagnostics.get("reason") or "Graph diagnostics marked this graph degraded.")
        return warnings

    def _refresh_all_summary(self, results: list[dict[str, Any]]) -> dict[str, Any]:
        return {
            "status": "ok",
            "summary": f"Processed {len(results)} indexed project graph(s).",
            "processed": len(results),
            "refreshed": len([item for item in results if item.get("status") == "ok"]),
            "skipped": len([item for item in results if item.get("status") == "skipped"]),
            "failed": len([item for item in results if item.get("status") == "error"]),
            "results": results,
        }

import unittest
import os
import json
import subprocess
import tempfile
from pathlib import Path
from unittest.mock import patch, MagicMock
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Soma"))
from soma_test_bootstrap import install_soma_imports

install_soma_imports()

from gateway.core import (
    _safe_text,
    _compact_result,
    _error_response,
    _ok_response,
    _parse_ports,
    NexusClient,
    NexusState,
)

from gateway.graphify_adapter import GraphifyAdapter
from gateway.memory_store import MemoryStore


class TestGraphifyAdapterAndMemoryStore(unittest.TestCase):
    def test_graphify_project_graph_candidates_none(self):
        adapter = GraphifyAdapter()
        self.assertEqual(adapter.project_graph_candidates(None), [])

    def test_graphify_project_graph_candidates_valid(self):
        with tempfile.TemporaryDirectory() as tmp:
            adapter = GraphifyAdapter(graph_dir=Path(tmp) / "graphs")
            candidates = adapter.project_graph_candidates("/my/project")

            self.assertGreaterEqual(len(candidates), 4)
            self.assertEqual(candidates[0], adapter.storage.graph_json("/my/project"))
            self.assertIn(Path("/my/project/graphify-out/graph.json"), candidates)
            self.assertIn(Path("/my/project/Assets/NexusUnity/graphify-out/graph.json"), candidates)

    def test_graphify_project_id_is_stable_and_collision_safe(self):
        with tempfile.TemporaryDirectory() as tmp:
            adapter = GraphifyAdapter(graph_dir=Path(tmp) / "graphs")
            first = adapter.storage.project_id("/repo/a/Soma")
            second = adapter.storage.project_id("/repo/a/./Soma")
            other = adapter.storage.project_id("/repo/b/Soma")

        self.assertEqual(first, second)
        self.assertNotEqual(first, other)

    def test_graphify_uses_assets_as_source_root_for_unity_projects(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "UnityProject"
            assets = root / "Assets"
            assets.mkdir(parents=True)
            (root / "ProjectSettings").mkdir()
            (root / "Library" / "PackageCache").mkdir(parents=True)
            adapter = GraphifyAdapter(graph_dir=Path(tmp) / "graphs")
            storage = adapter.storage.storage_info(str(root))

            self.assertTrue(adapter.storage.is_unity_project(str(root)))
            self.assertEqual(adapter.storage.graph_source_root(str(root)), assets.resolve(strict=False))
            self.assertEqual(storage["graph_scope"], "unity_assets")
            self.assertEqual(storage["graph_source_root"], str(assets.resolve(strict=False)))

    @patch.object(Path, "exists")
    def test_graphify_find_graphs_no_existing(self, mock_exists):
        mock_exists.return_value = False
        adapter = GraphifyAdapter()
        graphs = adapter.find_graphs("/my/project")
        self.assertEqual(graphs, [])

    def test_graphify_find_graphs_some_existing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "project"
            legacy = root / "graphify-out"
            legacy.mkdir(parents=True)
            (legacy / "graph.json").write_text('{"nodes":[],"edges":[]}', encoding="utf-8")
            adapter = GraphifyAdapter(graph_dir=Path(tmp) / "graphs")
            graphs = adapter.find_graphs(str(root))
            cross_project = adapter.find_graphs(str(root), project_only=False)

        self.assertEqual([str(path) for path in graphs], [str((legacy / "graph.json").resolve())])
        self.assertEqual(cross_project, graphs)

    def test_graphify_managed_graph_wins_over_legacy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "project"
            legacy = root / "graphify-out"
            legacy.mkdir(parents=True)
            (legacy / "graph.json").write_text('{"nodes":[{"id":"legacy"}],"edges":[]}', encoding="utf-8")
            adapter = GraphifyAdapter(graph_dir=Path(tmp) / "graphs")
            managed = adapter.storage.graph_dir(str(root))
            managed.mkdir(parents=True)
            (managed / "graph.json").write_text('{"nodes":[{"id":"managed"}],"edges":[{}]}', encoding="utf-8")
            graphs = adapter.find_graphs(str(root))
            status = adapter.status(str(root))

        self.assertEqual(graphs[0], managed / "graph.json")
        self.assertEqual(status["storage_kind"], "managed")
        self.assertTrue(status["managed_available"])
        self.assertTrue(status["legacy_available"])
        self.assertEqual(status["node_count"], 1)
        self.assertEqual(status["edge_count"], 1)

    def test_graphify_status_recommends_refresh_when_graph_built_with_older_tool(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "project"
            root.mkdir()
            adapter = GraphifyAdapter(graph_dir=Path(tmp) / "graphs")
            managed = adapter.storage.graph_dir(str(root))
            managed.mkdir(parents=True)
            (managed / "graph.json").write_text('{"nodes":[],"edges":[]}', encoding="utf-8")
            adapter.storage.update_index(
                root,
                {
                    "storagePath": str(managed),
                    "nodeCount": 0,
                    "edgeCount": 0,
                },
                graphify_version="0.8.17",
            )
            with patch.object(adapter.storage, "graphify_version", return_value="0.8.18"):
                status = adapter.status(str(root))

        self.assertEqual(status["tool_version"], "0.8.18")
        self.assertEqual(status["graphify_version"], "0.8.17")
        self.assertEqual(status["recommended_action"], "Refresh managed graph.")

    def test_graphify_tool_version_status_detects_outdated_tool(self):
        with tempfile.TemporaryDirectory() as tmp:
            adapter = GraphifyAdapter(graph_dir=Path(tmp) / "graphs")
            with (
                patch.object(adapter.storage, "graphify_version", return_value="0.8.17"),
                patch.object(adapter.storage, "latest_graphify_version", return_value="0.8.18"),
            ):
                status = adapter.storage.tool_version_status()

        self.assertFalse(status["up_to_date"])
        self.assertEqual(status["recommended_action"], "upgrade_tool")

    def test_refresh_managed_graph_uses_managed_output_and_does_not_create_project_graph(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "project"
            root.mkdir()
            adapter = GraphifyAdapter(graph_dir=Path(tmp) / "graphs")
            managed = adapter.storage.graph_dir(str(root))
            managed.mkdir(parents=True)
            (managed / "graph.json").write_text('{"nodes":[],"edges":[]}', encoding="utf-8")

            def fake_run(cmd, **kwargs):
                if "update" in cmd:
                    self.assertEqual(kwargs["env"]["GRAPHIFY_OUT"], str(managed))
                    (managed / "graph.json").write_text('{"nodes":[{"id":"A"}],"edges":[{}]}', encoding="utf-8")
                    return subprocess.CompletedProcess(cmd, 0, stdout="updated", stderr="")
                if "diagnose" in cmd:
                    payload = {
                        "summary": {
                            "node_count": 1,
                            "raw_edge_count": 1,
                            "directed_same_endpoint_collapsed_edges": 0,
                            "undirected_same_endpoint_collapsed_edges": 0,
                            "non_object_edges": 0,
                            "missing_endpoint_edges": 0,
                            "dangling_endpoint_edges": 0,
                            "post_build_error": "",
                        }
                    }
                    return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(payload), stderr="")
                if "--version" in cmd:
                    return subprocess.CompletedProcess(cmd, 0, stdout="graphify 0.8.18", stderr="")
                return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

            with (
                patch("gateway.graph_storage.subprocess.run", side_effect=fake_run),
                patch("gateway.graph_storage.shutil.which", return_value="graphify"),
                patch.object(adapter.storage, "_skip_refresh_reason", return_value=None),
            ):
                result = adapter.storage.refresh_managed_graph(str(root))

        self.assertEqual(result["status"], "ok")
        self.assertFalse((root / "graphify-out").exists())
        self.assertEqual(result["graph"]["node_count"], 1)

    def test_refresh_managed_graph_scans_unity_assets_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "UnityProject"
            assets = root / "Assets"
            assets.mkdir(parents=True)
            (root / "ProjectSettings").mkdir()
            (root / "Library" / "PackageCache").mkdir(parents=True)
            adapter = GraphifyAdapter(graph_dir=Path(tmp) / "graphs")
            managed = adapter.storage.graph_dir(str(root))
            managed.mkdir(parents=True)
            (managed / "graph.json").write_text('{"nodes":[],"edges":[]}', encoding="utf-8")

            def fake_run(cmd, **kwargs):
                if "update" in cmd:
                    self.assertIn("--force", cmd)
                    self.assertEqual(cmd[-1], str(assets.resolve(strict=False)))
                    self.assertEqual(kwargs["env"]["GRAPHIFY_OUT"], str(managed))
                    (managed / "graph.json").write_text('{"nodes":[{"id":"A"}],"edges":[]}', encoding="utf-8")
                    return subprocess.CompletedProcess(cmd, 0, stdout="updated assets", stderr="")
                if "diagnose" in cmd:
                    payload = {
                        "summary": {
                            "node_count": 1,
                            "raw_edge_count": 0,
                            "directed_same_endpoint_collapsed_edges": 0,
                            "undirected_same_endpoint_collapsed_edges": 0,
                            "non_object_edges": 0,
                            "missing_endpoint_edges": 0,
                            "dangling_endpoint_edges": 0,
                            "post_build_error": "",
                        }
                    }
                    return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(payload), stderr="")
                if "--version" in cmd:
                    return subprocess.CompletedProcess(cmd, 0, stdout="graphify 0.8.18", stderr="")
                return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

            with (
                patch("gateway.graph_storage.subprocess.run", side_effect=fake_run),
                patch("gateway.graph_storage.shutil.which", return_value="graphify"),
                patch.object(adapter.storage, "_skip_refresh_reason", return_value=None),
            ):
                result = adapter.storage.refresh_managed_graph(str(root))

        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["graphScope"], "unity_assets")
        self.assertEqual(result["graphSourceRoot"], str(assets.resolve(strict=False)))
        self.assertFalse((root / "graphify-out").exists())
        self.assertFalse((assets / "graphify-out").exists())

    def test_refresh_all_managed_graphs_skips_temp_and_missing_roots(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "project"
            root.mkdir()
            adapter = GraphifyAdapter(graph_dir=Path(tmp) / "graphs")
            managed = adapter.storage.graph_dir(str(root))
            managed.mkdir(parents=True)
            (managed / "graph.json").write_text('{"nodes":[],"edges":[]}', encoding="utf-8")
            data = {
                "projects": {
                    adapter.storage.project_id(root): {"projectRoot": str(root)},
                    "tmp": {"projectRoot": "/private/tmp/soma-fixture"},
                    "missing": {"projectRoot": str(Path(tmp) / "missing")},
                }
            }
            adapter.storage.write_index(data)

            def fake_refresh(project_root, *, full=False):
                return {"status": "ok", "projectRoot": str(project_root)}

            original_skip = adapter.storage._skip_refresh_reason

            def fake_skip(path):
                if path == root.resolve(strict=False):
                    return None
                return original_skip(path)

            with (
                patch.object(adapter.storage, "refresh_managed_graph", side_effect=fake_refresh),
                patch.object(adapter.storage, "_skip_refresh_reason", side_effect=fake_skip),
            ):
                result = adapter.storage.refresh_all_managed_graphs()

        self.assertEqual(result["refreshed"], 1)
        self.assertEqual(result["skipped"], 2)


if __name__ == "__main__":
    unittest.main()

import unittest
import os
import json
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
    NexusState
)

from gateway.graphify_adapter import GraphifyAdapter
from gateway.memory_store import MemoryStore

class TestGatewayCoreBasic(unittest.TestCase):

    def test_safe_text_string_no_truncation(self):
        text = "short string"
        self.assertEqual(_safe_text(text, 50), text)

    def test_safe_text_string_truncation(self):
        text = "very long string here"
        self.assertEqual(_safe_text(text, 9), "very long")

    def test_safe_text_dict_json_conversion(self):
        data = {"key": "value"}
        res = _safe_text(data, 100)
        self.assertEqual(res, json.dumps(data))

    def test_safe_text_dict_truncation(self):
        data = {"key": "value"}
        res = _safe_text(data, 5)
        self.assertEqual(res, json.dumps(data)[:5])

    def test_compact_result_basic(self):
        res_str = _compact_result("ok", "a summary")
        res = json.loads(res_str)
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["summary"], "a summary")
        self.assertEqual(res["evidence"], [])
        self.assertEqual(res["omitted"], {})
        self.assertEqual(res["next_calls"], [])

    def test_error_response_structure(self):
        res_str = _error_response("something failed", next_calls=["retry"])
        res = json.loads(res_str)
        self.assertEqual(res["status"], "error")
        self.assertEqual(res["summary"], "something failed")
        self.assertEqual(res["next_calls"], ["retry"])

    def test_ok_response_structure(self):
        res_str = _ok_response("all good", omitted={"key": "val"})
        res = json.loads(res_str)
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["summary"], "all good")
        self.assertEqual(res["omitted"], {"key": "val"})

    @patch.dict(os.environ, {"NEXUS_PORT": "8082", "NEXUS_PORTS": "8083,8084"}, clear=True)
    def test_parse_ports_from_env(self):
        ports = _parse_ports()
        self.assertEqual(ports[:3], [8082, 8083, 8084])
        self.assertIn(8090, ports)

    def test_nexus_client_url_default(self):
        client = NexusClient(ports=[8085])
        client.state = NexusState()
        self.assertEqual(client._url(), "http://127.0.0.1:8085/")

    def test_nexus_client_url_override(self):
        client = NexusClient(ports=[8085])
        client.state = NexusState()
        client.state.port = 8086
        self.assertEqual(client._url(8087), "http://127.0.0.1:8087/")

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

    @patch.object(Path, 'exists')
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

    def test_memory_store_project_dir_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch('gateway.memory_store.SOMA_MEMORY_DIR', Path(tmp)):
                store = MemoryStore()
                p_dir = store.project_dir(None)
                self.assertEqual(p_dir, Path(tmp) / "default")
                self.assertTrue(p_dir.exists())

    def test_memory_store_project_dir_custom(self):
        with tempfile.TemporaryDirectory() as tmp:
            custom_project = Path(tmp) / "my_project"
            store = MemoryStore()
            p_dir = store.project_dir(str(custom_project))
            self.assertEqual(p_dir, custom_project / ".soma")
            self.assertTrue(p_dir.exists())

    def test_memory_store_load_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            custom_project = Path(tmp) / "my_project"
            store = MemoryStore()
            mem = store.load(str(custom_project))
            self.assertEqual(mem, {"notes": [], "known_issues": [], "patterns": []})

    def test_memory_store_load_with_legacy_memory(self):
        with tempfile.TemporaryDirectory() as tmp:
            custom_project = Path(tmp) / "my_project"
            store = MemoryStore()

            p_dir = store.project_dir(str(custom_project))
            (p_dir / "memory.json").write_text('{"notes": [{"text": "legacy note"}], "patterns": ["pattern1"]}')

            mem = store.load(str(custom_project))
            self.assertEqual(len(mem["notes"]), 1)
            self.assertEqual(mem["notes"][0]["text"], "legacy note")
            self.assertIn("pattern1", mem["patterns"])

    def test_memory_store_load_with_known_issues(self):
        with tempfile.TemporaryDirectory() as tmp:
            custom_project = Path(tmp) / "my_project"
            store = MemoryStore()

            p_dir = store.project_dir(str(custom_project))
            (p_dir / "known_issues.json").write_text('[{"text": "issue 1"}]')

            mem = store.load(str(custom_project))
            self.assertEqual(len(mem["known_issues"]), 1)
            self.assertEqual(mem["known_issues"][0]["text"], "issue 1")

    def test_memory_store_load_with_known_issues_dict(self):
        with tempfile.TemporaryDirectory() as tmp:
            custom_project = Path(tmp) / "my_project"
            store = MemoryStore()

            p_dir = store.project_dir(str(custom_project))
            (p_dir / "known_issues.json").write_text('{"known_issues": [{"text": "dict issue"}]}')

            mem = store.load(str(custom_project))
            self.assertEqual(len(mem["known_issues"]), 1)
            self.assertEqual(mem["known_issues"][0]["text"], "dict issue")

from gateway.core import (
    _packet_budget,
    _analysis_depth,
    _evidence_summary,
    _enforce_packet_budget,
    get_active_project_root,
    TOKEN_BUDGETS,
    DEFAULT_TOKEN_BUDGET
)

class TestGatewayCoreAdvanced(unittest.TestCase):

    def test_packet_budget_valid(self):
        self.assertEqual(_packet_budget("fast"), "fast")
        self.assertEqual(_packet_budget("deep"), "deep")

    def test_packet_budget_invalid(self):
        self.assertEqual(_packet_budget("invalid_budget"), DEFAULT_TOKEN_BUDGET)

    def test_analysis_depth_valid(self):
        self.assertEqual(_analysis_depth("analyst"), "analyst")

    def test_analysis_depth_invalid(self):
        self.assertEqual(_analysis_depth("unknown_depth"), "deterministic")

    def test_evidence_summary_truncates(self):
        items = [{"path": f"f{i}", "kind": "file", "reason": f"r{i}"} for i in range(10)]
        summary = _evidence_summary(items, limit=3)
        self.assertEqual(len(summary), 3)
        self.assertEqual(summary[0]["path"], "f0")

    def test_evidence_summary_symbols_truncated(self):
        item = {"path": "f1", "kind": "file", "reason": "r1", "symbols": ["s" + str(i) for i in range(10)]}
        summary = _evidence_summary([item])
        self.assertEqual(len(summary[0]["symbols"]), 6)

    def test_evidence_summary_empty(self):
        self.assertEqual(_evidence_summary([]), [])

    @patch('gateway.core.estimate_tokens')
    def test_enforce_packet_budget_under_budget(self, mock_estimate):
        mock_estimate.return_value = 100
        packet = "some small packet"
        result = _enforce_packet_budget("my goal", {}, packet, "fast")
        self.assertEqual(result, packet)

    @patch('gateway.core.estimate_tokens')
    def test_enforce_packet_budget_over_budget(self, mock_estimate):
        # We need it to be over budget, so it enters the fallback logic
        # Then inside the fallback logic it estimates the fallback packet,
        # so we mock side_effect to return > budget then < budget
        mock_estimate.side_effect = [999999, 100]
        bundle = {
            "evidence_items": [{"path": "f1", "kind": "file", "reason": "r1"}],
            "omitted_context": {"key": "value"}
        }
        result = _enforce_packet_budget("my goal", bundle, "some massive packet", "fast")

        self.assertIn("Goal:", result)
        self.assertIn("my goal", result)
        self.assertIn("- f1 [file]: r1", result)
        self.assertIn("- key: value", result)

    @patch('os.path.isdir')
    @patch.dict(os.environ, {"SOMA_PROJECT_ROOT": "/custom/path"}, clear=True)
    def test_get_active_project_root_env(self, mock_isdir):
        mock_isdir.return_value = True

        with patch('scout_pipeline.normalize_path', side_effect=lambda x: x):
            self.assertEqual(get_active_project_root(), "/custom/path")

if __name__ == '__main__':
    unittest.main()

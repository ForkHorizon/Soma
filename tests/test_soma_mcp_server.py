import gateway
import os
import asyncio
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Soma"))

import scout_pipeline
import gateway.server
import gateway.core
import gateway.tools.nexus
import gateway.tools.query
import gateway.tools.context
import gateway.tools.memory


class SomaMCPServerTests(unittest.TestCase):
    def setUp(self):
        import os
        self.previous_project_root = os.environ.get("SOMA_PROJECT_ROOT")

    def tearDown(self):
        if self.previous_project_root:
            os.environ["SOMA_PROJECT_ROOT"] = self.previous_project_root
        elif "SOMA_PROJECT_ROOT" in os.environ:
            del os.environ["SOMA_PROJECT_ROOT"]

    def make_repo(self):
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "Soma").mkdir()
        (root / "Soma" / "relay.py").write_text("MODEL = 'gemma4:e4b'\n\ndef relay():\n    return 'ok'\n")
        (root / "Soma" / "ContentView.swift").write_text(
            "import SwiftUI\n\nstruct ContentView: View {\n    var body: some View { Text(\"Soma\") }\n}\n"
        )
        (root / "README.md").write_text("Soma test repo\n")
        subprocess.run(["git", "init"], cwd=root, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-m", "init"], cwd=root, check=True, capture_output=True)
        (root / "Soma" / "relay.py").write_text("MODEL = 'gemma4:e4b'\n\ndef relay():\n    raise RuntimeError('slow')\n")
        return tmp, root

    def test_tool_catalog_stays_small_and_soma_scoped(self):
        status_payload = gateway.server.build_status_payload()
        names = status_payload["server"]["tool_names"]

        self.assertEqual(len(names), 12)
        self.assertIn("soma_prepare_context", names)
        self.assertIn("soma_apply", names)
        self.assertFalse(any(name.startswith("unity_") for name in names))

    def test_prepare_context_returns_structured_budgeted_packet(self):
        tmp, root = self.make_repo()
        with tmp, patch.object(
            gateway.core.graphify,
            "query",
            return_value={"graphs": [], "answers": [], "warnings": []},
        ):
            import os
            os.environ["SOMA_PROJECT_ROOT"] = str(root)
            payload = json.loads(asyncio.run(gateway.tools.context.soma_prepare_context("do we have bugs?", "micro", "deterministic")))

        self.assertEqual(payload["status"], "ok")
        self.assertIn("packet", payload)
        self.assertLessEqual(payload["estimated_tokens"], scout_pipeline.TOKEN_BUDGETS["micro"])
        self.assertIn("omitted", payload)
        self.assertNotIn("diff --git", payload["packet"])

    def test_graph_unavailable_degrades_cleanly(self):
        with patch.object(
            gateway.core.graphify,
            "query",
            return_value={"graphs": [], "answers": [], "warnings": ["graphify unavailable"]},
        ):
            payload = json.loads(asyncio.run(gateway.tools.query.soma_ask("what owns relay?")))

        self.assertEqual(payload["status"], "degraded")
        self.assertIn("next_calls", payload)
        self.assertIn("warnings", payload["omitted"])

    def test_client_config_snippets_point_to_soma_only(self):
        codex = gateway.server.build_client_config("codex", "/tmp/project", "/usr/bin/python3")
        gemini = json.loads(gateway.server.build_client_config("gemini", "/tmp/project", "/usr/bin/python3"))
        claude = json.loads(gateway.server.build_client_config("claude", "/tmp/project", "/usr/bin/python3"))
        normalized_root = scout_pipeline.normalize_path("/tmp/project")

        self.assertIn("[mcp_servers.soma]", codex)
        self.assertIn("soma_mcp_server.py", codex)
        self.assertNotIn("nexus_unity_bridge", codex)
        self.assertEqual(gemini["mcpServers"]["soma"]["env"]["SOMA_PROJECT_ROOT"], normalized_root)
        self.assertEqual(claude["mcpServers"]["soma"]["command"], "/usr/bin/python3")

    def test_verify_codex_config_detects_direct_nexus(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.toml"
            config.write_text(
                "\n".join(
                    [
                        "[mcp_servers.soma]",
                        'command = "/usr/bin/python3"',
                        'args = ["/tmp/soma_mcp_server.py"]',
                        "",
                        "[mcp_servers.nexus-unity]",
                        'command = "/usr/bin/python3"',
                        'args = ["/tmp/nexus_unity_bridge.py"]',
                    ]
                )
            )

            payload = gateway.server.verify_codex_config(config)

        self.assertEqual(payload["status"], "degraded")
        self.assertTrue(payload["soma_installed"])
        self.assertTrue(payload["direct_nexus_exposed"])
        self.assertIn("direct_nexus_exposed", payload["issues"])

    def test_install_codex_config_backs_up_and_removes_direct_nexus(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.toml"
            config.write_text(
                "\n".join(
                    [
                        'model = "gpt-5.5"',
                        "",
                        "[mcp_servers.nexus-unity]",
                        'command = "/usr/bin/python3"',
                        'args = ["/tmp/nexus_unity_bridge.py"]',
                    ]
                )
            )

            payload = gateway.server.install_codex_config(config, "/tmp/project", "/usr/bin/python3")
            updated = config.read_text()
            backup = Path(payload["backup_path"])
            backup_exists = backup.exists()

        self.assertEqual(payload["status"], "ok")
        self.assertTrue(backup_exists)
        self.assertIn("[mcp_servers.soma]", updated)
        self.assertIn("soma_mcp_server.py", updated)
        self.assertIn('model = "gpt-5.5"', updated)
        self.assertNotIn("[mcp_servers.nexus-unity]", updated)
        self.assertNotIn("nexus_unity_bridge", updated)
        self.assertTrue(payload["direct_nexus_removed"])

    def test_install_codex_config_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.toml"
            config.write_text("[mcp_servers.soma]\ncommand = \"/bad/python\"\nargs = [\"/bad/soma_mcp_server.py\"]\n")

            first = gateway.server.install_codex_config(config, "/tmp/project", "/usr/bin/python3")
            second = gateway.server.install_codex_config(config, "/tmp/project", "/usr/bin/python3")
            updated = config.read_text()
            backups = list(Path(tmp).glob("config.toml.soma-backup-*"))

        self.assertEqual(first["status"], "ok")
        self.assertEqual(second["status"], "ok")
        self.assertEqual(updated.count("[mcp_servers.soma]"), 1)
        self.assertNotIn("/bad/python", updated)
        self.assertGreaterEqual(len(backups), 2)

    def test_rollback_codex_config_restores_latest_backup(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.toml"
            config.write_text("[mcp_servers.soma]\ncommand = \"/new/python\"\nargs = [\"/new/soma_mcp_server.py\"]\n")
            older = Path(tmp) / "config.toml.soma-backup-20260101-000000"
            newer = Path(tmp) / "config.toml.soma-backup-20260102-000000"
            older.write_text('model = "old"\n')
            newer.write_text('model = "latest"\n')

            payload = gateway.server.rollback_codex_config(config)
            restored = config.read_text()

        self.assertEqual(payload["status"], "ok")
        self.assertTrue(payload["restored"])
        self.assertIn('model = "latest"', restored)

    def test_rollback_codex_config_uses_explicit_backup_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.toml"
            explicit = Path(tmp) / "manual-backup.toml"
            config.write_text("current\n")
            explicit.write_text("explicit\n")

            payload = gateway.server.rollback_codex_config(config, explicit)
            restored = config.read_text()

        self.assertEqual(payload["status"], "ok")
        self.assertEqual(restored, "explicit\n")

    def test_rollback_codex_config_reports_missing_backup(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.toml"
            config.write_text("current\n")

            payload = gateway.server.rollback_codex_config(config)
            restored = config.read_text()

        self.assertEqual(payload["status"], "degraded")
        self.assertFalse(payload["restored"])
        self.assertIn("missing_backup", payload["issues"])
        self.assertEqual(restored, "current\n")

    def test_graph_status_reports_missing_graph(self):
        tmp = tempfile.TemporaryDirectory()
        with tmp:
            adapter = gateway.core.GraphifyAdapter(graph_dir=Path(tmp.name) / "graphs")
            status = adapter.status(str(Path(tmp.name) / "project"))

        self.assertFalse(status["project_graph_available"])
        self.assertIn("graphify", status["recommended_action"])

    def test_status_payload_reports_tool_catalog_and_graph(self):
        tmp, root = self.make_repo()
        with tmp, patch.object(gateway.core.nexus, "discover", return_value=gateway.core.NexusState()):
            payload = gateway.server.build_status_payload(str(root))

        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["server"]["tool_count"], 12)
        self.assertFalse(any(name.startswith("unity_") for name in payload["server"]["tool_names"]))
        self.assertIn("graph", payload)

    def test_memory_stores_structured_notes_without_raw_chat_requirement(self):
        tmp, root = self.make_repo()
        with tmp:
            import os
            os.environ["SOMA_PROJECT_ROOT"] = str(root)
            payload = json.loads(
                asyncio.run(gateway.tools.memory.soma_remember("save", "Port conflicts happen during Unity reload.", "known_issues"))
            )
            known_issues = json.loads((root / ".soma" / "known_issues.json").read_text())

        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["memory_counts"]["known_issues"], 1)
        self.assertIn("Port conflicts", known_issues[0]["text"])

    def test_nexus_unavailable_returns_safe_error(self):
        with patch.object(gateway.core.nexus, "available", return_value=False):
            payload = json.loads(asyncio.run(gateway.tools.nexus.soma_scene()))

        self.assertEqual(payload["status"], "error")
        self.assertIn("Nexus Unity not connected", payload["summary"])
        self.assertTrue(payload["next_calls"])

    def test_get_map_uses_nexus_mock_and_graph_status(self):
        tmp, root = self.make_repo()
        state = gateway.core.NexusState(connected=True, port=8081, project_path=str(root), session_id="abc123", session_generation=3)
        with tmp, patch.object(gateway.core.nexus, "discover", return_value=state), patch.object(
            gateway.core.nexus,
            "compact_scene_snapshot",
            return_value={"result": {"scene_name": "Main", "total_objects": 1}},
        ), patch.object(
            gateway.core.nexus,
            "read_logs",
            return_value={"result": {"logs": []}},
        ):
            import os
            os.environ["SOMA_PROJECT_ROOT"] = str(root)
            payload = json.loads(asyncio.run(gateway.tools.context.soma_get_map()))

        self.assertEqual(payload["status"], "ok")
        self.assertTrue(payload["map"]["nexus"]["connected"])
        self.assertIn("graph", payload["map"])

    def test_soma_execute_blocks_recursive_batch(self):
        with patch.object(gateway.core.nexus, "available", return_value=True):
            payload = json.loads(asyncio.run(gateway.tools.nexus.soma_execute([{"method": "batch_execute", "params": {}}])))

        self.assertEqual(payload["status"], "error")
        self.assertIn("blocked", payload["omitted"])

    def test_soma_apply_uses_nexus_macro_shape(self):
        with patch.object(gateway.core.nexus, "available", return_value=True), patch.object(
            gateway.core.nexus,
            "apply_code_change",
            return_value={"result": {"status": "Success", "compiler_errors": []}},
        ):
            payload = json.loads(
                asyncio.run(gateway.tools.nexus.soma_apply([{"path": "Assets/Test.cs", "content": "class Test {}"}]))
            )

        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["omitted"]["file_count"], 1)
        self.assertEqual(payload["result"]["status"], "Success")

    def test_soma_delta_uses_previous_scene_generation(self):
        tmp, root = self.make_repo()
        state = gateway.core.NexusState(connected=True, port=8081, project_path=str(root), session_generation=9)
        with tmp, patch.object(gateway.core.nexus, "discover", return_value=state), patch.object(
            gateway.core.nexus,
            "timeline",
            return_value={"result": {"events": []}},
        ), patch.object(
            gateway.core.nexus,
            "scene_delta",
            return_value={"result": {"changes": []}},
        ) as scene_delta:
            import os
            os.environ["SOMA_PROJECT_ROOT"] = str(root)
            gateway.core._last_scene_generation = 7
            payload = json.loads(asyncio.run(gateway.tools.nexus.soma_delta()))

        self.assertEqual(payload["status"], "ok")
        scene_delta.assert_called_once_with(7)
        self.assertEqual(gateway.core._last_scene_generation, 9)


if __name__ == "__main__":
    unittest.main()

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
from soma_test_bootstrap import install_soma_imports
install_soma_imports()

import gateway
import scout_pipeline
import gateway.server
import gateway.core
import gateway.tools.nexus
import gateway.tools.query
import gateway.tools.context
import gateway.tools.memory
import gateway.tool_registry
import gateway.jsonrpc
import gateway.client_config
import verify_soma_mcp_clients
import soma_language_optimizer
import soma_logger
import soma_audit
import soma_project_setup
import extension_manager


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

    def test_tool_schema_exposes_prepare_context_inputs(self):
        schema = gateway.tool_registry.tool_schema("soma_prepare_context")
        self.assertEqual(schema["properties"]["goal"]["type"], "string")
        self.assertIn("goal", schema["required"])
        self.assertFalse(schema["additionalProperties"])

    def test_tool_descriptor_exposes_signature(self):
        descriptor = gateway.tool_registry.tool_descriptor("soma_prepare_context")

        self.assertEqual(descriptor["signature"], 'soma_prepare_context(goal: string, budget: string = "balanced", depth: string = "deterministic") -> string')
        self.assertEqual(descriptor["_meta"]["soma_signature"], descriptor["signature"])
        self.assertIn("inputSchema", descriptor)

    def test_jsonrpc_tools_list_exposes_signatures(self):
        payload = json.loads(asyncio.run(gateway.jsonrpc._dispatch("tools/list", {})))
        signatures = {tool["name"]: tool.get("signature") for tool in payload["tools"]}

        self.assertEqual(len(signatures), 12)
        self.assertTrue(all(signatures.values()))
        self.assertEqual(signatures["soma_get_map"], "soma_get_map() -> string")

    def test_tool_call_ignores_client_added_arguments(self):
        tmp, root = self.make_repo()
        with tmp, patch.object(gateway.core.nexus, "discover", return_value=gateway.core.NexusState()), patch.object(
            gateway.core.graphify,
            "status",
            return_value={"stale": True, "recommended_action": "Run graphify in the project root."},
        ), patch.object(gateway.core.graphify, "god_nodes_from_report", return_value=[]):
            os.environ["SOMA_PROJECT_ROOT"] = str(root)
            payload = json.loads(asyncio.run(gateway.tool_registry.call_tool("soma_get_map", {"wait_for_previous": True})))

        self.assertEqual(payload["status"], "ok")

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
        self.assertTrue(any("client='codex'" in item for item in payload["next_calls"]))
        self.assertTrue(any("soma_code_context" in item for item in payload["next_calls"]))

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
        hermes = gateway.server.build_client_config("hermes", "/tmp/project", "/usr/bin/python3")
        normalized_root = scout_pipeline.normalize_path("/tmp/project")

        self.assertIn("[mcp_servers.soma]", codex)
        self.assertIn("soma_mcp_server.py", codex)
        self.assertNotIn("nexus_unity_bridge", codex)
        self.assertEqual(gemini["mcpServers"]["soma"]["env"]["SOMA_PROJECT_ROOT"], normalized_root)
        self.assertEqual(claude["mcpServers"]["soma"]["command"], "/usr/bin/python3")
        self.assertIn("mcp_servers:", hermes)
        self.assertIn("  soma:", hermes)
        self.assertIn("soma_mcp_server.py", hermes)
        self.assertIn(f'SOMA_PROJECT_ROOT: "{normalized_root}"', hermes)

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

    def test_verify_codex_config_detects_wrong_project_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.toml"
            config.write_text(
                "\n".join(
                    [
                        "[mcp_servers.soma]",
                        'command = "/usr/bin/python3"',
                        'args = ["/tmp/soma_mcp_server.py", "--project-root", "/tmp/old"]',
                        'env = { SOMA_PROJECT_ROOT = "/tmp/old" }',
                    ]
                )
            )

            payload = gateway.server.verify_codex_config(config, "/tmp/new")

        self.assertEqual(payload["status"], "degraded")
        self.assertFalse(payload["project_matches"])
        self.assertIn("project_root_mismatch", payload["issues"])

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

    def test_install_gemini_config_preserves_settings_and_removes_direct_nexus(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "settings.json"
            config.write_text(
                json.dumps(
                    {
                        "general": {"defaultApprovalMode": "auto_edit"},
                        "mcpServers": {
                            "nexus-unity": {"command": "/usr/bin/python3", "args": ["nexus_unity_bridge.py"]},
                            "other": {"command": "echo", "args": ["ok"]},
                        },
                    }
                )
            )

            payload = gateway.server.install_gemini_config(config, "/tmp/project", "/usr/bin/python3")
            updated = json.loads(config.read_text())
            backup_exists = Path(payload["backup_path"]).exists()

        self.assertEqual(payload["status"], "ok")
        self.assertTrue(backup_exists)
        self.assertEqual(updated["general"]["defaultApprovalMode"], "auto_edit")
        self.assertIn("soma", updated["mcpServers"])
        self.assertIn("other", updated["mcpServers"])
        self.assertNotIn("nexus-unity", updated["mcpServers"])
        self.assertTrue(payload["direct_nexus_removed"])
        self.assertTrue(payload["project_matches"])

    def test_verify_gemini_config_detects_direct_nexus_and_wrong_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "settings.json"
            config.write_text(
                json.dumps(
                    {
                        "mcpServers": {
                            "soma": {
                                "command": "/usr/bin/python3",
                                "args": ["/tmp/soma_mcp_server.py", "--project-root", "/tmp/old"],
                                "env": {"SOMA_PROJECT_ROOT": "/tmp/old"},
                            },
                            "unity": {"command": "unity_mcp"},
                        }
                    }
                )
            )

            payload = gateway.server.verify_gemini_config(config, "/tmp/new")

        self.assertEqual(payload["status"], "degraded")
        self.assertTrue(payload["direct_nexus_exposed"])
        self.assertFalse(payload["project_matches"])
        self.assertIn("direct_nexus_exposed", payload["issues"])
        self.assertIn("project_root_mismatch", payload["issues"])

    def test_extension_manager_repairs_antigravity_json_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            config = home / ".gemini/antigravity-ide/mcp_config.json"
            config.parent.mkdir(parents=True)
            config.write_text(
                json.dumps(
                    {
                        "mcpServers": {
                            "nexus-unity": {"command": "python3", "args": ["nexus_unity_bridge.py"]},
                            "soma": {
                                "command": "/usr/bin/python3",
                                "args": ["/tmp/soma_mcp_server.py", "--project-root", "/tmp/old"],
                                "env": {"SOMA_PROJECT_ROOT": "/tmp/old"},
                            },
                        }
                    }
                )
            )

            before = extension_manager.verify_ai_clients("/tmp/project", [], home=home)
            synced = extension_manager.sync_ai_clients("/tmp/project", [], home=home)
            updated = json.loads(config.read_text())

        self.assertEqual(before["status"], "degraded")
        self.assertNotIn("nexus-unity", updated["mcpServers"])
        self.assertIn("soma", updated["mcpServers"])
        self.assertIn("antigravity", {item["client"] for item in synced["clients"]})

    def test_extension_manager_degrades_when_project_root_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "settings.json"
            config.write_text(json.dumps({"mcpServers": {"soma": {"command": "/usr/bin/python3", "args": ["/tmp/soma_mcp_server.py"]}}}))

            payload = extension_manager._verify_json_config(config, "/tmp/project")

        self.assertEqual(payload["status"], "degraded")
        self.assertIn("project_root_missing", payload["issues"])

    def test_extension_manager_update_does_not_sync_after_failed_update(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            before = {"tool_id": "graphify", "installed_version": "1.0.0", "latest_version": "1.0.1"}
            failed = subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="failed")

            with patch.object(extension_manager, "_tool_status_one", side_effect=[before, before]), patch.object(extension_manager, "_run_shell", return_value=failed), patch.object(extension_manager, "sync_ai_clients") as sync:
                payload = extension_manager.update_tool("graphify", "/tmp/project", [], home=home)

        sync.assert_not_called()
        self.assertEqual(payload["status"], "degraded")
        self.assertIn("update_command_failed", payload["issues"])
        self.assertNotIn("smoke_failed", payload["issues"])
        self.assertEqual(payload["clients"], [])

    def test_extension_manager_backup_names_do_not_collide(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.json"
            config.write_text("{}")
            first = extension_manager._backup(config)
            first.write_text("{}")

            second = extension_manager._backup(config)

        self.assertNotEqual(first, second)

    def test_extension_manager_disables_antigravity_direct_tool_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            direct = home / ".gemini/antigravity/mcp/nexus-unity"
            direct.mkdir(parents=True)
            (direct / "unity_wait.json").write_text("{}")
            (home / ".gemini/antigravity/mcp/soma").mkdir()

            synced = extension_manager.sync_ai_clients(None, [], home=home)

            tool_statuses = [item for item in synced["clients"] if item["client"] == "antigravity" and "antigravity/mcp" in item["config_path"]]
            self.assertEqual(tool_statuses[0]["status"], "ok")
            self.assertFalse(direct.exists())
            self.assertTrue(any(path.name.startswith("nexus-unity.disabled-soma-backup-") for path in direct.parent.iterdir()))

    def test_extension_manager_scans_project_markers(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            project = home / "Daliys/App"
            project.mkdir(parents=True)
            (project / ".mcp.json").write_text("{}")

            report = extension_manager.scan_ai_clients(None, [], home=home)

        self.assertIn(str(project.resolve()), {item["project_root"] for item in report["projects"]})

    def test_extension_manager_sets_up_memory_tools_for_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "home"
            root = Path(tmp) / "project"
            home.mkdir()
            root.mkdir()
            ok = subprocess.CompletedProcess(args=[], returncode=0, stdout="ok", stderr="")

            with patch.object(extension_manager, "_installed_version", return_value="1.0.0"), patch.object(
                extension_manager, "_latest_version", return_value="1.0.0"
            ), patch.object(
                extension_manager, "_codebase_memory_bin", return_value="/bin/echo"
            ), patch.object(
                extension_manager, "_projectmem_cli", return_value="/bin/echo"
            ), patch.object(
                extension_manager, "_run", return_value=ok
            ):
                report = extension_manager.setup_memory_tools(str(root), home=home)

            codex_config = home / ".codex/config.toml"
            gemini_config = home / ".gemini/settings.json"
            agents = root / "AGENTS.md"

            self.assertEqual(report["status"], "ok")
            self.assertIn("mcp_servers.projectmem", codex_config.read_text())
            self.assertIn("projectmem", json.loads(gemini_config.read_text())["mcpServers"])
            agents_text = agents.read_text()
            self.assertIn("Default mode: light", agents_text)
            self.assertIn("Codebase-Memory:", agents_text)
            self.assertIn("projectmem:", agents_text)

    def test_extension_manager_sets_up_single_project_tool(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "home"
            root = Path(tmp) / "project"
            codebase_root = Path(tmp) / "codebase-project"
            home.mkdir()
            root.mkdir()
            codebase_root.mkdir()
            ok = subprocess.CompletedProcess(args=[], returncode=0, stdout="ok", stderr="")

            with patch.object(extension_manager, "_installed_version", return_value="1.0.0"), patch.object(
                extension_manager, "_projectmem_cli", return_value="/bin/echo"
            ), patch.object(
                extension_manager, "_codebase_memory_bin", return_value="/bin/echo"
            ), patch.object(extension_manager, "_run", return_value=ok):
                report = extension_manager.setup_project_tool("projectmem", str(root), home=home)
                codebase_report = extension_manager.setup_project_tool("codebase-memory", str(codebase_root), home=home)
                unsupported = extension_manager.setup_project_tool("serena", str(root), home=home)

            self.assertEqual(report["status"], "ok")
            self.assertEqual(report["tool_id"], "projectmem")
            self.assertIn("mcp_servers.projectmem", (home / ".codex/config.toml").read_text())
            projectmem_agents = (root / "AGENTS.md").read_text()
            self.assertIn("projectmem:", projectmem_agents)
            self.assertNotIn("Codebase-Memory:", projectmem_agents)
            self.assertEqual(codebase_report["status"], "ok")
            codebase_agents = (codebase_root / "AGENTS.md").read_text()
            self.assertIn("Codebase-Memory:", codebase_agents)
            self.assertNotIn("projectmem:", codebase_agents)
            self.assertEqual(unsupported["status"], "error")
            self.assertIn("unsupported_project_tool", unsupported["issues"])

    def test_project_overview_reports_dirty_git_repo(self):
        tmp, root = self.make_repo()
        with tmp, tempfile.TemporaryDirectory() as home_tmp:
            home = Path(home_tmp)
            other = home / "Daliys/Other"
            other.mkdir(parents=True)
            (other / "AGENTS.md").write_text("Other project\n")
            (home / ".gemini").mkdir()
            (home / ".gemini/settings.json").write_text(json.dumps({"mcpServers": {"soma": {"command": sys.executable, "args": ["/tmp/soma_mcp_server.py", "--project-root", str(other)], "env": {"SOMA_PROJECT_ROOT": str(other)}}}}))
            (root / ".gemini").mkdir()
            (root / ".gemini/settings.json").write_text(json.dumps({"mcpServers": {"soma": {"command": sys.executable, "args": ["/tmp/soma_mcp_server.py", "--project-root", str(root)], "env": {"SOMA_PROJECT_ROOT": str(root)}}}}))
            subprocess.run(["git", "add", ".gemini/settings.json"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-m", "config"], cwd=root, check=True, capture_output=True)
            (root / "scratch.txt").write_text("new\n")

            with patch.object(extension_manager, "_installed_version", return_value="1.0.0"), patch.object(
                extension_manager, "_latest_version", return_value="1.0.0"
            ), patch.object(extension_manager, "_codebase_memory_indexed", return_value=True):
                payload = extension_manager.project_overview(str(root), [], home=home, graph_status={"project_graph_available": True, "stale": False})

        self.assertEqual(payload["git"]["is_repo"], True)
        self.assertEqual(payload["git"]["changed_count"], 2)
        self.assertEqual(payload["git"]["untracked_count"], 1)
        self.assertEqual(payload["memory"]["codebase_memory_indexed"], True)
        self.assertEqual([item["id"] for item in payload["memory"]["installed_tools"]], ["codebase-memory", "graphify"])
        self.assertNotIn("tools", payload)
        self.assertNotIn("known_project_alerts", payload)
        self.assertEqual([item["project_root"] for item in payload["clients"]], [scout_pipeline.normalize_path(str(root))])

    def test_project_overview_handles_non_git_and_missing_roots(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "home"
            root = Path(tmp) / "project"
            missing = Path(tmp) / "missing"
            home.mkdir()
            root.mkdir()

            with patch.object(extension_manager, "_installed_version", return_value=None), patch.object(extension_manager, "_latest_version", return_value=None):
                non_git = extension_manager.project_overview(str(root), [], home=home)
                missing_payload = extension_manager.project_overview(str(missing), [], home=home)

        self.assertFalse(non_git["git"]["is_repo"])
        self.assertEqual(non_git["memory"]["status"], "none")
        self.assertEqual(non_git["memory"]["installed_tools"], [])
        self.assertEqual(non_git["memory"]["issues"], [])
        self.assertFalse(missing_payload["git"]["is_repo"])
        self.assertIn("missing_project_root", missing_payload["issues"])

    def test_install_hermes_config_preserves_settings_and_removes_direct_nexus(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.yaml"
            config.write_text(
                "\n".join(
                    [
                        'default_model: "gpt-5"',
                        "mcp_servers:",
                        "  nexus-unity:",
                        '    command: "/usr/bin/python3"',
                        '    args: ["/tmp/nexus_unity_bridge.py"]',
                        "    enabled: true",
                        "  other:",
                        '    command: "echo"',
                        '    args: ["ok"]',
                        "storage:",
                        '  base_dir: "/tmp/hermes"',
                        "",
                    ]
                ),
                encoding="utf-8",
            )

            with patch.object(gateway.client_config.shutil, "which", return_value="/usr/local/bin/hermes"):
                payload = gateway.server.install_hermes_config(config, "/tmp/project", "/usr/bin/python3")
            updated = config.read_text(encoding="utf-8")
            backup_exists = Path(payload["backup_path"]).exists()

        self.assertEqual(payload["status"], "ok")
        self.assertTrue(backup_exists)
        self.assertIn('default_model: "gpt-5"', updated)
        self.assertIn("  other:", updated)
        self.assertIn("storage:", updated)
        self.assertIn("  soma:", updated)
        self.assertIn("soma_mcp_server.py", updated)
        self.assertNotIn("nexus-unity", updated)
        self.assertNotIn("nexus_unity_bridge", updated)
        self.assertTrue(payload["direct_nexus_removed"])
        self.assertTrue(payload["project_matches"])

    def test_verify_hermes_config_detects_disabled_direct_nexus_and_wrong_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.yaml"
            config.write_text(
                "\n".join(
                    [
                        "mcp_servers:",
                        "  soma:",
                        '    command: "/usr/bin/python3"',
                        '    args: ["/tmp/soma_mcp_server.py", "--project-root", "/tmp/old"]',
                        "    env:",
                        '      SOMA_PROJECT_ROOT: "/tmp/old"',
                        "    enabled: false",
                        "  unity:",
                        '    command: "unity_mcp"',
                        "",
                    ]
                ),
                encoding="utf-8",
            )

            with patch.object(gateway.client_config.shutil, "which", return_value="/usr/local/bin/hermes"):
                payload = gateway.server.verify_hermes_config(config, "/tmp/new")

        self.assertEqual(payload["status"], "degraded")
        self.assertFalse(payload["soma_installed"])
        self.assertTrue(payload["direct_nexus_exposed"])
        self.assertFalse(payload["project_matches"])
        self.assertIn("soma_server_disabled", payload["issues"])
        self.assertIn("direct_nexus_exposed", payload["issues"])
        self.assertIn("project_root_mismatch", payload["issues"])

    def test_mcp_smoke_client_statuses_include_hermes(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.yaml"
            config.write_text(gateway.server.build_client_config("hermes", "/tmp/project", "/usr/bin/python3"), encoding="utf-8")
            args = type(
                "Args",
                (),
                {
                    "clients": "hermes",
                    "codex_config_path": None,
                    "gemini_config_path": None,
                    "hermes_config_path": str(config),
                },
            )()

            with patch.object(gateway.client_config.shutil, "which", return_value="/usr/local/bin/hermes"):
                statuses = verify_soma_mcp_clients._client_config_statuses(args, scout_pipeline.normalize_path("/tmp/project"))

        self.assertIn("hermes", statuses)
        self.assertEqual(statuses["hermes"]["status"], "ok")

    def test_verify_hermes_config_degrades_when_cli_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.yaml"
            config.write_text(gateway.server.build_client_config("hermes", "/tmp/project", "/usr/bin/python3"), encoding="utf-8")

            with patch.object(gateway.client_config.shutil, "which", return_value=None):
                payload = gateway.server.verify_hermes_config(config, "/tmp/project")

        self.assertEqual(payload["status"], "degraded")
        self.assertTrue(payload["soma_installed"])
        self.assertFalse(payload["client_available"])
        self.assertIn("hermes_cli_missing", payload["issues"])

    def test_rollback_gemini_config_restores_latest_backup(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "settings.json"
            config.write_text('{"mcpServers":{"soma":{}}}\n')
            older = Path(tmp) / "settings.json.soma-backup-20260101-000000"
            newer = Path(tmp) / "settings.json.soma-backup-20260102-000000"
            older.write_text('{"general":{"value":"old"}}\n')
            newer.write_text('{"general":{"value":"latest"}}\n')

            payload = gateway.server.rollback_gemini_config(config)
            restored = json.loads(config.read_text())

        self.assertEqual(payload["status"], "ok")
        self.assertTrue(payload["restored"])
        self.assertEqual(restored["general"]["value"], "latest")

    def test_project_ai_setup_analyze_detects_project_local_conflicts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "project"
            root.mkdir()
            (root / ".gemini").mkdir()
            project_gemini = root / ".gemini" / "settings.json"
            project_gemini.write_text(
                json.dumps(
                    {
                        "mcpServers": {
                            "nexus-unity": {"command": "/usr/bin/python3", "args": ["/tmp/nexus_unity_bridge.py"]},
                            "soma": {
                                "command": "/usr/bin/python3",
                                "args": ["/tmp/soma_mcp_server.py", "--project-root", "/tmp/old"],
                            },
                        },
                        "general": {"defaultApprovalMode": "auto_edit"},
                    }
                ),
                encoding="utf-8",
            )
            (root / "GEMINI.md").write_text("Use raw unity_apply_code_change first.\n", encoding="utf-8")
            (root / "AGENTS.md").write_text("Read graphify-out before inspecting files.\n", encoding="utf-8")
            report_dir = Path(tmp) / "reports"
            with patch.object(soma_project_setup, "REPORT_DIR", report_dir), patch.object(
                soma_project_setup, "LATEST_REPORT", report_dir / "latest.json"
            ):
                report = soma_project_setup.analyze_project_ai_setup(str(root))

        self.assertEqual(report["status"], "degraded")
        self.assertIn("direct_mcp_server_exposed", report["issues"])
        self.assertIn("missing_soma_first_block", report["issues"])
        self.assertIn("graphify_first_instruction", report["issues"])
        self.assertEqual(report["files_changed"], [])

    def test_project_ai_setup_harden_preserves_settings_and_adds_soma_first_block(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "project"
            root.mkdir()
            (root / ".gemini").mkdir()
            (root / ".codex").mkdir()
            project_gemini = root / ".gemini" / "settings.json"
            project_gemini.write_text(
                json.dumps(
                    {
                        "general": {"defaultApprovalMode": "auto_edit"},
                        "mcpServers": {
                            "nexus-unity": {"command": "/usr/bin/python3", "args": ["/tmp/nexus_unity_bridge.py"]},
                            "other": {"command": "echo", "args": ["ok"]},
                        },
                    }
                ),
                encoding="utf-8",
            )
            prompt = root / "GEMINI.md"
            prompt.write_text("# Project Rules\n\nUse raw unity tools for scene work.\n", encoding="utf-8")
            codex_config = root / ".codex" / "config.toml"
            codex_config.write_text('model = "gpt-5.5"\n', encoding="utf-8")
            global_gemini = Path(tmp) / "home" / ".gemini" / "settings.json"
            global_codex = Path(tmp) / "home" / ".codex" / "config.toml"
            report_dir = Path(tmp) / "reports"
            with patch.object(soma_project_setup, "REPORT_DIR", report_dir), patch.object(
                soma_project_setup, "LATEST_REPORT", report_dir / "latest.json"
            ), patch.object(
                soma_project_setup, "gemini_config_default_path", return_value=global_gemini
            ), patch.object(
                gateway.client_config, "gemini_config_default_path", return_value=global_gemini
            ), patch.object(
                gateway.client_config, "codex_config_default_path", return_value=global_codex
            ), patch.dict(
                os.environ, {"SOMA_PROJECT_ONBOARDING_USE_LOCAL_AI": "0"}
            ):
                report = soma_project_setup.harden_project_ai_setup(str(root), python_executable="/usr/bin/python3")
                updated_project_gemini = json.loads(project_gemini.read_text(encoding="utf-8"))
                updated_prompt = prompt.read_text(encoding="utf-8")

        self.assertEqual(report["status"], "ok")
        self.assertEqual(updated_project_gemini["general"]["defaultApprovalMode"], "auto_edit")
        self.assertIn("soma", updated_project_gemini["mcpServers"])
        self.assertIn("other", updated_project_gemini["mcpServers"])
        self.assertNotIn("nexus-unity", updated_project_gemini["mcpServers"])
        self.assertIn("Soma First Workflow", updated_prompt)
        self.assertIn("soma_code_context", updated_prompt)
        self.assertIn('workflow="live_mcp"', updated_prompt)
        self.assertIn("Use raw unity tools", updated_prompt)
        self.assertGreaterEqual(len(report["backups"]), 3)
        self.assertTrue(any(item["backup_path"] for item in report["backups"]))

    def test_project_ai_setup_rollback_restores_latest_backups(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "project"
            root.mkdir()
            (root / ".gemini").mkdir()
            project_gemini = root / ".gemini" / "settings.json"
            original_json = json.dumps({"mcpServers": {"nexus-unity": {"command": "nexus_unity_bridge.py"}}}) + "\n"
            project_gemini.write_text(original_json, encoding="utf-8")
            prompt = root / "GEMINI.md"
            original_prompt = "# Project Rules\nUse raw Nexus.\n"
            prompt.write_text(original_prompt, encoding="utf-8")
            global_gemini = Path(tmp) / "home" / ".gemini" / "settings.json"
            global_codex = Path(tmp) / "home" / ".codex" / "config.toml"
            report_dir = Path(tmp) / "reports"
            with patch.object(soma_project_setup, "REPORT_DIR", report_dir), patch.object(
                soma_project_setup, "LATEST_REPORT", report_dir / "latest.json"
            ), patch.object(
                soma_project_setup, "gemini_config_default_path", return_value=global_gemini
            ), patch.object(
                gateway.client_config, "gemini_config_default_path", return_value=global_gemini
            ), patch.object(
                gateway.client_config, "codex_config_default_path", return_value=global_codex
            ), patch.dict(
                os.environ, {"SOMA_PROJECT_ONBOARDING_USE_LOCAL_AI": "0"}
            ):
                soma_project_setup.harden_project_ai_setup(str(root), python_executable="/usr/bin/python3")
                rollback = soma_project_setup.rollback_project_ai_setup(str(root))
                restored_project_gemini = project_gemini.read_text(encoding="utf-8")
                restored_prompt = prompt.read_text(encoding="utf-8")

        self.assertEqual(rollback["status"], "ok")
        self.assertEqual(restored_project_gemini, original_json)
        self.assertEqual(restored_prompt, original_prompt)

    def test_jsonrpc_supports_initialize_and_tools_list(self):
        init_payload = json.loads(asyncio.run(gateway.jsonrpc._dispatch("initialize", {})))
        tools_payload = json.loads(asyncio.run(gateway.jsonrpc._dispatch("tools/list", {})))

        self.assertEqual(init_payload["serverInfo"]["name"], "soma-gateway")
        self.assertEqual(len(tools_payload["tools"]), 12)
        self.assertTrue(all(tool["name"].startswith("soma_") for tool in tools_payload["tools"]))
        self.assertIn("inputSchema", tools_payload["tools"][0])

    def test_mcp_smoke_report_marks_plugin_tools_guarded_when_nexus_offline(self):
        args = type(
            "Args",
            (),
            {
                "project_root": None,
                "clients": "",
                "python": sys.executable,
                "timeout": 1.0,
                "codex_config_path": None,
                "gemini_config_path": None,
                "hermes_config_path": None,
            },
        )()
        tmp, root = self.make_repo()
        with tmp, patch.object(verify_soma_mcp_clients, "_client_config_statuses", return_value={}), patch.object(
            verify_soma_mcp_clients, "CORE_CALLS", {}
        ), patch.object(gateway.core.nexus, "discover", return_value=gateway.core.NexusState()):
            args.project_root = str(root)
            report = verify_soma_mcp_clients.run_smoke(args)

        self.assertIn(report["status"], {"ok", "degraded"})
        self.assertEqual(report["plugin_status"]["unity_nexus"], "skipped")
        plugin_results = {item["tool"]: item for item in report["tool_results"] if item["tool"] in {"soma_apply", "soma_execute"}}
        self.assertEqual(plugin_results["soma_apply"]["status"], "skipped")
        self.assertIn("plugin_guarded", plugin_results["soma_apply"]["reason"])

    def test_tool_log_records_translation_metadata_without_raw_prompt(self):
        tmp, root = self.make_repo()
        russian_prompt = "Проверь quiet hours и верни план."

        def fake_translate(text, model, timeout):
            return "Check quiet hours and return a plan."

        with tmp, tempfile.TemporaryDirectory() as log_tmp, patch.object(
            gateway.core.graphify, "query", return_value={"graphs": [], "answers": [], "warnings": []}
        ), patch.object(soma_language_optimizer, "_local_ollama_translate", side_effect=fake_translate), patch.object(
            soma_logger, "SOMA_LOG_DIR", Path(log_tmp)
        ), patch.object(
            soma_logger, "SOMA_SESSION_STATS_FILE", Path(log_tmp) / "session_stats.json"
        ), patch.object(
            soma_audit, "SOMA_AUDIT_DIR", Path(log_tmp) / "audit"
        ), patch.object(
            soma_audit, "SOMA_AUDIT_RUNS_DIR", Path(log_tmp) / "audit" / "runs"
        ), patch.object(
            soma_audit, "SOMA_AUDIT_RAW_DIR", Path(log_tmp) / "audit" / "raw"
        ), patch.object(
            soma_audit, "SOMA_AUDIT_LATEST", Path(log_tmp) / "audit" / "latest.json"
        ), patch.dict(
            os.environ,
            {"SOMA_PROJECT_ROOT": str(root), "SOMA_TRANSLATION_ENABLED": "1", "SOMA_TRANSLATION_PROVIDER": "local"},
        ):
            payload = json.loads(
                asyncio.run(
                    gateway.tool_registry.call_tool(
                        "soma_prepare_context",
                        {"goal": russian_prompt, "budget": "micro", "depth": "deterministic", "run_id": "run_log_translation", "task_id": "translation"},
                    )
                )
            )
            log_text = "\n".join(path.read_text() for path in Path(log_tmp).glob("soma_*.jsonl"))
            audit_latest = json.loads(soma_audit.SOMA_AUDIT_LATEST.read_text(encoding="utf-8"))

        self.assertIn(payload["language_optimization"]["status"], {"translated", "failed_fallback"})
        self.assertEqual(payload["audit"]["run_id"], "run_log_translation")
        self.assertIn("\"run_id\": \"run_log_translation\"", log_text)
        self.assertIn("translation_status", log_text)
        self.assertIn("prompt_saved_tokens", log_text)
        self.assertNotIn("Проверь", log_text)
        self.assertTrue(any(call.get("tool") == "soma_prepare_context" for call in audit_latest.get("tool_calls", [])))

    def test_graph_status_reports_missing_graph(self):
        tmp = tempfile.TemporaryDirectory()
        with tmp:
            adapter = gateway.core.GraphifyAdapter(graph_dir=Path(tmp.name) / "graphs")
            status = adapter.status(str(Path(tmp.name) / "project"))

        self.assertFalse(status["project_graph_available"])
        self.assertEqual(status["storage_kind"], "missing")
        self.assertIn("managed graph", status["recommended_action"])

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

    def test_soma_execute_compacts_large_output_by_default(self):
        large = {"items": [{"message": "x" * 1000} for _ in range(20)]}
        with patch.object(gateway.core.nexus, "available", return_value=True), patch.object(
            gateway.core.nexus,
            "batch_execute",
            return_value={"result": large},
        ), patch.dict(os.environ, {"SOMA_AUDIT_RAW_CAPTURE": "0"}):
            payload = json.loads(asyncio.run(gateway.tools.nexus.soma_execute([{"method": "read_logs", "params": {}}])))

        self.assertEqual(payload["status"], "ok")
        self.assertTrue(payload["omitted"]["output_truncated"])
        self.assertGreater(payload["omitted"]["omitted_output_tokens"], 0)
        self.assertIn("raw_output_hash", payload["result"])
        self.assertNotIn("x" * 1000, json.dumps(payload["result"]))

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

import asyncio
import contextlib
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Soma"))

import scout_pipeline
import scout_pipeline_module.llama as llama
from scout_pipeline_module.ranker import pinned_evidence_ids
import soma_logger


class FakeHTTPResponse:
    def __init__(self, body: str):
        self.body = body.encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self):
        return self.body


class ScoutPipelineTests(unittest.TestCase):
    def run_gather(self, prompt, project_root, *extra_args):
        defaults = ("balanced", False, "deterministic", "standard", "off")
        if len(extra_args) < len(defaults):
            extra_args = tuple(extra_args) + defaults[len(extra_args):]
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            asyncio.run(
                scout_pipeline.run_gather(
                    prompt,
                    str(project_root),
                    "[]",
                    *extra_args,
                )
            )
        return json.loads(stdout.getvalue())

    def make_repo(self):
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "Soma").mkdir()
        (root / "Soma" / "relay.py").write_text("MODEL = 'gemma4:e4b'\n\ndef relay():\n    return 'ok'\n")
        (root / "Soma" / "ContentView.swift").write_text("import SwiftUI\n\nstruct ContentView: View {\n    var body: some View { Text(\"Soma\") }\n}\n")
        (root / "Package.swift").write_text("// swift-tools-version: 5.9\n")
        (root / "ollama_logs.txt").write_text("INFO server started\n")
        (root / "README.md").write_text("old readme\n")
        subprocess.run(["git", "init"], cwd=root, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-m", "init"], cwd=root, check=True, capture_output=True)
        (root / "Soma" / "relay.py").write_text("MODEL = 'gemma4:e4b'\n\ndef relay():\n    return 'fast'\n")
        (root / "README.md").write_text("new readme\n")
        (root / ".DS_Store").write_text("noise")
        (root / "Soma" / "__pycache__").mkdir()
        (root / "Soma" / "__pycache__" / "relay.cpython-313.pyc").write_bytes(b"noise")
        return tmp, root

    def test_gather_omits_raw_git_diff(self):
        tmp, root = self.make_repo()
        with tmp:
            bundle = self.run_gather("relay is slow, check diff", root, "fast", False)

        self.assertIsNone(bundle["git_diff"])
        # git_diff_summary may be None if Go daemon is unavailable
        if bundle["git_diff_summary"] is not None:
            self.assertGreater(bundle["git_diff_summary"]["raw_diff_chars_omitted"], 0)
        self.assertNotIn("diff --git", bundle["codex_packet"])
        self.assertLessEqual(bundle["estimated_tokens"], scout_pipeline.TOKEN_BUDGETS["fast"])

    def test_explicit_project_file_is_prioritized(self):
        tmp, root = self.make_repo()
        with tmp:
            explicit = root / "Soma" / "relay.py"
            bundle = self.run_gather(f"check {explicit} for relay latency", root, "fast", False)

        self.assertTrue(bundle["evidence_items"])
        self.assertEqual(bundle["evidence_items"][0]["path"], scout_pipeline.normalize_path(explicit))

    def test_general_prompt_direct_pass(self):
        tmp, root = self.make_repo()
        with tmp:
            bundle = self.run_gather("explain this app", root, "fast", False)

        self.assertEqual(bundle["routing_decision"], "direct_pass_through")
        self.assertEqual(bundle["codex_packet"], "explain this app")
        self.assertEqual(bundle["evidence_items"], [])

    def test_typo_changed_prompt_triggers_changes_mode(self):
        tmp, root = self.make_repo()
        with tmp:
            bundle = self.run_gather("What we changet", root, "balanced", False)

        self.assertEqual(bundle["packet_mode"], "changes")
        self.assertEqual(bundle["routing_decision"], "gathered_and_relayed")

    def test_changed_prompt_triggers_changes_mode(self):
        tmp, root = self.make_repo()
        with tmp:
            bundle = self.run_gather("what changed", root, "balanced", False)

        self.assertEqual(bundle["packet_mode"], "changes")

    def test_bugs_prompt_triggers_review_mode(self):
        tmp, root = self.make_repo()
        with tmp:
            bundle = self.run_gather("do we have bugs?", root, "balanced", False)

        self.assertEqual(bundle["packet_mode"], "review")

    def test_weak_debug_prompt_compiles_model_ready_packet_with_evidence(self):
        tmp, root = self.make_repo()
        with tmp:
            game_dir = root / "Game"
            game_dir.mkdir()
            (game_dir / "JumpController.swift").write_text(
                "final class JumpController {\n"
                "    func jump() { fatalError(\"jump force missing\") }\n"
                "}\n"
            )
            (root / "runtime.log").write_text(
                "INFO boot\n"
                "ERROR page 23: JumpController failed to apply jump force\n"
                "Traceback: jump broke after input\n"
            )
            bundle = self.run_gather(
                "My jump broke in the game and the console has an error on page 23.",
                root,
                "balanced",
                False,
            )

        self.assertEqual(bundle["routing_decision"], "gathered_and_relayed")
        self.assertEqual(bundle["packet_mode"], "debug")
        self.assertTrue(bundle["codex_packet"])
        self.assertTrue(bundle["evidence_items"])
        self.assertTrue(any(item["kind"] == "log" for item in bundle["evidence_items"]))
        self.assertTrue(bundle["error_lines"])
        self.assertIn("Goal:", bundle["codex_packet"])
        self.assertIn("Evidence:", bundle["codex_packet"])
        self.assertIn("Normalized errors:", bundle["codex_packet"])
        self.assertIn("Expected Codex behavior:", bundle["codex_packet"])

    def test_local_ai_prompt_prefers_ollama_swift_context_over_python_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Soma.xcodeproj").mkdir()
            (root / "Soma" / "ViewModels").mkdir(parents=True)
            (root / "Soma" / "Views").mkdir(parents=True)
            (root / "tests" / "fixtures").mkdir(parents=True)
            (root / "requirements.txt").write_text("pytest\n")
            (root / "Soma" / "ViewModels" / "OllamaManager.swift").write_text(
                "final class OllamaManager {\n"
                "    var isModelLoaded = false\n"
                "    var isOllamaRunning = false\n"
                "    func launchOllama() {}\n"
                "    func startModel() {}\n"
                "    func sendKeepAlive() {}\n"
                "}\n"
            )
            (root / "Soma" / "Views" / "GlobalSettingsBar.swift").write_text(
                "struct GlobalSettingsBar { let ollama: OllamaManager }\n"
            )
            (root / "Soma" / "ViewModels" / "SomaViewModel+Logs.swift").write_text(
                "struct LocalAIMetrics { let local_ai_call_count = 0 }\n"
            )
            (root / "tests" / "fixtures" / "fixture.log").write_text("ERROR stale fixture failure\n")
            bundle = self.run_gather(
                "Implement and verify local AI loads automatically and do not reload when already loaded.",
                root,
                "balanced",
                False,
            )

        evidence_paths = [item["path"] for item in bundle["evidence_items"]]
        self.assertEqual(bundle["project_type"], "swift")
        self.assertTrue(any(path.endswith("OllamaManager.swift") for path in evidence_paths))
        self.assertFalse(bundle["error_lines"])
        self.assertNotIn("stale fixture failure", bundle["codex_packet"])

    def test_local_ai_configurable_unload_pins_runtime_and_settings_context(self):
        preflight = {
            "expanded_terms": [
                "local",
                "ai",
                "ollama",
                "configurable",
                "interval",
                "time",
                "application",
                "state",
            ]
        }
        evidence = [
            {"path": "/repo/Soma/ViewModels/OllamaManager.swift"},
            {"path": "/repo/Soma/ViewModels/SomaViewModel+Execution.swift"},
            {"path": "/repo/Soma/Views/GlobalSettingsBar.swift"},
            {"path": "/repo/Soma/ViewModels/SomaViewModel.swift"},
        ]

        pinned = pinned_evidence_ids(
            "Implement local AI configurable unload interval in the app.",
            preflight,
            evidence,
        )

        self.assertEqual(pinned, [0, 2, 3])

    def test_gather_marks_graphify_skipped_when_project_graph_is_missing(self):
        tmp, root = self.make_repo()
        with tmp:
            bundle = self.run_gather("relay is slow, check diff", root, "balanced", False)

        omitted = bundle["omitted_context"]
        self.assertEqual(omitted["graphify"], "skipped")
        self.assertEqual(omitted["graph_answers"], 0)
        self.assertTrue(omitted["graph_warnings"])

    def test_gather_summarizes_graphify_hints_when_project_graph_is_available(self):
        tmp, root = self.make_repo()
        graph_result = {
            "graphs": [str(root / "graphify-out" / "graph.json")],
            "answers": [
                {
                    "graph": str(root / "graphify-out" / "graph.json"),
                    "answer": "Graph says Soma/ViewModels/OllamaManager.swift owns the local AI lifecycle.",
                }
            ],
            "warnings": [],
            "project_only": True,
        }
        with tmp, patch("scout_pipeline_module.pipeline._query_graphify_context", return_value=graph_result):
            bundle = self.run_gather("review local AI lifecycle and settings", root, "balanced", False)

        self.assertEqual(bundle["omitted_context"]["graphify"], "project_only")
        self.assertEqual(bundle["omitted_context"]["graph_answers"], 1)
        self.assertIn("Graph suggestions:", bundle["codex_packet"])
        self.assertIn("OllamaManager.swift owns the local AI lifecycle", bundle["codex_packet"])
        self.assertNotIn("Graph context (from Graphify):", bundle["codex_packet"])

    def test_gather_uses_graphify_hints_as_file_signal_without_raw_context(self):
        tmp, root = self.make_repo()
        hinted = root / "Soma" / "ContentView.swift"
        graph_result = {
            "graphs": [str(root / "graphify-out" / "graph.json")],
            "answers": [
                {
                    "graph": str(root / "graphify-out" / "graph.json"),
                    "answer": "Graph suggested Soma/ContentView.swift because it owns the primary SwiftUI entry surface.",
                }
            ],
            "warnings": [],
            "project_only": True,
        }
        with tmp, patch("scout_pipeline_module.pipeline._query_graphify_context", return_value=graph_result):
            bundle = self.run_gather("review packet UI surface", root, "balanced", False)

        hinted_path = scout_pipeline.normalize_path(str(hinted))
        self.assertIn(hinted_path, bundle["omitted_context"]["graph_suggested_files"])
        self.assertTrue(any(item["path"] == hinted_path for item in bundle["evidence_items"]))
        self.assertNotIn("Graph context (from Graphify):", bundle["codex_packet"])

    def test_candidate_filter_normalizes_string_notes(self):
        response = {"message": {"content": "{\"selected_ids\":[1],\"notes\":\"picked manifest\"}"}}
        evidence = [
            {"path": "/repo/A.cs", "kind": "source", "reason": "", "preview": "", "symbols": []},
            {"path": "/repo/AndroidManifest.xml", "kind": "config", "reason": "", "preview": "", "symbols": []},
        ]
        preflight = {"packet_mode": "review", "terms": ["apk"], "expanded_terms": ["apk", "android", "icon"]}
        with patch("scout_pipeline.query_ollama_model", new=AsyncMock(return_value=response)):
            _, stage = asyncio.run(
                scout_pipeline.filter_candidates_with_model(
                    "Investigate apk icon issue.",
                    preflight,
                    evidence,
                    max_items=1,
                )
            )

        self.assertEqual(stage["notes"], ["picked manifest"])

    def test_unity_apk_icon_prompt_includes_icon_and_manifest_context(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Assets" / "Plugins" / "Android").mkdir(parents=True)
            (root / "Assets" / "Visual" / "Sprites" / "Icon").mkdir(parents=True)
            (root / "ProjectSettings").mkdir()
            (root / "ProjectSettings" / "ProjectSettings.asset").write_text(
                "PlayerSettings:\n"
                "  companyName: test\n"
                "  platformSettings:\n"
                "  - serializedVersion: 3\n"
                "    m_BuildTarget: Android\n"
                "    m_Icons:\n"
                "    - m_Textures:\n"
                "      - {fileID: 2800000, guid: icon-guid, type: 3}\n"
            )
            (root / "ProjectSettings" / "GraphicsSettings.asset").write_text(
                "GraphicsSettings:\n  m_CustomRenderPipeline: {fileID: 0}\n"
            )
            (root / "Assets" / "Plugins" / "Android" / "AndroidManifest.xml").write_text(
                "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\">\n"
                "  <application android:icon=\"@mipmap/app_icon\" />\n"
                "</manifest>\n"
            )
            (root / "Assets" / "Visual" / "Sprites" / "Icon" / "Icon.png.meta").write_text(
                "fileFormatVersion: 2\n"
                "guid: icon-guid\n"
                "TextureImporter:\n"
                "  textureType: 8\n"
                "  platformSettings:\n"
                "  - name: Android\n"
                "    overridden: 1\n"
            )
            bundle = self.run_gather(
                "Investigate issue where apk icon becomes incorrect.",
                root,
                "balanced",
                False,
            )

        paths = [item["path"].replace("\\", "/") for item in bundle["evidence_items"]]
        self.assertTrue(any(path.endswith("/ProjectSettings/ProjectSettings.asset") for path in paths))
        self.assertTrue(any(path.endswith("/Assets/Plugins/Android/AndroidManifest.xml") for path in paths))
        self.assertTrue(any(path.endswith("/Assets/Visual/Sprites/Icon/Icon.png.meta") for path in paths))
        self.assertIn("m_Icons", bundle["codex_packet"])
        self.assertIn("m_BuildTarget: Android", bundle["codex_packet"])

    def test_prompt_compiler_profile_omits_generic_git_and_metrics_sections(self):
        tmp, root = self.make_repo()
        with tmp:
            bundle = self.run_gather(
                "check relay diff",
                root,
                "balanced",
                False,
                "deterministic",
                "prompt_compiler",
            )

        packet = bundle["codex_packet"]
        self.assertIn("Focused Evidence:", packet)
        self.assertNotIn("Git status:", packet)
        self.assertNotIn("Git diff summary:", packet)
        self.assertNotIn("Token budget:", packet)
        self.assertNotIn("Omitted context:", packet)
        self.assertNotIn("Graph context (from Graphify):", packet)

    def test_prompt_compiler_open_source_review_focuses_unity_package_not_wrapper(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package_root = root / "Assets" / "NexusUnity"
            (package_root / "Editor" / "Tests").mkdir(parents=True)
            (package_root / "Runtime").mkdir(parents=True)
            (root / "ProjectSettings").mkdir()
            (root / "Assets").mkdir(exist_ok=True)
            (root / "AutoSavedScene.unity").write_text("Main Camera\nm_Name: Test Wrapper Scene\n")
            (root / "ProjectSettings" / "ProjectSettings.asset").write_text(
                "PlayerSettings:\n  applicationIdentifier:\n    Android: com.UnityTechnologies.wrapper\n"
            )
            (root / "package.json").write_text(
                '{"name":"com.custom.wrapper","displayName":"Nexus Unity","version":"3.1.2"}\n'
            )
            (package_root / "package.json").write_text(
                '{"name":"com.forkhorizon.nexus.unity","displayName":"Nexus Unity",'
                '"version":"1.0.0","license":"GPL-3.0-only",'
                '"description":"Open source Unity Editor automation server."}\n'
            )
            (package_root / "README.md").write_text(
                "# Nexus Unity\n\nOpen source Unity Editor automation package.\n"
            )
            (package_root / "LICENSE.md").write_text("GPL-3.0-only\n")
            (package_root / "CHANGELOG.md").write_text("## [1.0.0]\n- First public release.\n")
            (package_root / "Editor" / "MCPServer.cs").write_text("public static class MCPServer {}\n")
            (package_root / "Editor" / "Tests" / "OpenSourceApiContractTests.cs").write_text(
                "public class OpenSourceApiContractTests {}\n"
            )
            bundle = self.run_gather(
                "We are preparing Nexus Unity for open source. Root is only a wrapper for testing; analyze weak and strong places before release.",
                root,
                "balanced",
                False,
                "deterministic",
                "prompt_compiler",
                "off",
            )

        packet = bundle["codex_packet"]
        focused_evidence = packet.split("Focused Evidence:", 1)[1].split("Expected answer:", 1)[0]
        evidence_paths = [item["path"].replace("\\", "/") for item in bundle["evidence_items"]]
        self.assertEqual(bundle["packet_mode"], "review")
        self.assertTrue(bundle["preflight"]["focus_root"].replace("\\", "/").endswith("/Assets/NexusUnity"))
        self.assertTrue(any(path.endswith("/Assets/NexusUnity/package.json") for path in evidence_paths))
        self.assertTrue(any(path.endswith("/Assets/NexusUnity/README.md") for path in evidence_paths))
        self.assertTrue(any(path.endswith("/Assets/NexusUnity/LICENSE.md") for path in evidence_paths))
        self.assertIn("open-source readiness review", packet)
        self.assertIn("Collection Plan:", packet)
        self.assertIn("Focus:", packet)
        self.assertIn("Assets/NexusUnity/package.json", packet)
        self.assertNotIn("AutoSavedScene.unity", packet)
        self.assertNotIn("ProjectSettings.asset", packet)

    def test_prompt_compiler_stress_uses_planned_package_scope_over_wrapper_noise(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package_root = root / "Assets" / "NexusUnity"
            (package_root / "Editor" / "Tests").mkdir(parents=True)
            (package_root / "Runtime").mkdir(parents=True)
            (root / "Assets" / "Plugins" / "Android").mkdir(parents=True)
            (root / "Assets" / "Visual" / "Sprites" / "Icon").mkdir(parents=True)
            (root / "ProjectSettings").mkdir()
            (root / "Library" / "PackageCache" / "com.noise").mkdir(parents=True)
            (root / ".soma" / "graphify-out").mkdir(parents=True)

            (root / "AutoSavedScene.unity").write_text(
                "GameObject:\n  m_Name: Wrapper Smoke Test Scene\n  m_TagString: MainCamera\n"
            )
            (root / "ProjectSettings" / "ProjectSettings.asset").write_text(
                "PlayerSettings:\n"
                "  applicationIdentifier:\n"
                "    Android: com.UnityTechnologies.wrapper\n"
                "  m_BuildTargetPlatformIcons:\n"
                "  - m_BuildTarget: Android\n"
            )
            (root / "Assets" / "Plugins" / "Android" / "AndroidManifest.xml").write_text(
                '<manifest><application android:icon="@mipmap/app_icon" /></manifest>\n'
            )
            (root / "Assets" / "Visual" / "Sprites" / "Icon" / "ICON5.png.meta").write_text(
                "guid: wrappericon\nTextureImporter:\n  textureType: 8\n"
            )
            (root / "Library" / "PackageCache" / "com.noise" / "package.json").write_text(
                '{"name":"com.generated.noise","displayName":"Generated Nexus Unity Noise"}\n'
            )
            (root / ".soma" / "graphify-out" / "graph.json").write_text("{}\n")
            (root / "package.json").write_text(
                '{"name":"com.wrapper.host","displayName":"Nexus Unity Wrapper Host"}\n'
            )
            (root / "README.md").write_text(
                "# Wrapper Host\n\nThis project only exists to test the Nexus Unity package.\n"
            )

            (package_root / "package.json").write_text(
                '{"name":"com.forkhorizon.nexus.unity","displayName":"Nexus Unity",'
                '"version":"2.8.0","license":"GPL-3.0-only",'
                '"description":"Open source Unity MCP bridge and editor automation package."}\n'
            )
            (package_root / "README.md").write_text(
                "# Nexus Unity\n\nPublic package docs, setup, MCP bridge usage, and release notes.\n"
            )
            (package_root / "LICENSE.md").write_text("GPL-3.0-only\n")
            (package_root / "CHANGELOG.md").write_text("## 2.8.0\n- Prepare public release.\n")
            (package_root / "DOCUMENTATION.MD").write_text(
                "# API\n\nDocuments tools, resources, prompts, and setup flows.\n"
            )
            (package_root / "Editor" / "MCPServer.cs").write_text(
                "namespace NexusUnity.Editor { public static class MCPServer { public static void Start() {} } }\n"
            )
            (package_root / "Editor" / "MCPServerMethods.cs").write_text(
                "namespace NexusUnity.Editor { public static class MCPServerMethods { public static void Register() {} } }\n"
            )
            (package_root / "Runtime" / "NexusUnityClient.cs").write_text(
                "namespace NexusUnity.Runtime { public sealed class NexusUnityClient {} }\n"
            )
            (package_root / "Editor" / "Tests" / "OpenSourceReadinessTests.cs").write_text(
                "namespace NexusUnity.Tests { public sealed class OpenSourceReadinessTests {} }\n"
            )

            planner_response = {
                "message": {
                    "content": json.dumps(
                        {
                            "task_type": "release_readiness",
                            "target_scope": "unity_package",
                            "scope_hints": ["Assets/NexusUnity", "Nexus Unity"],
                            "required_evidence": [
                                "package_manifest",
                                "readme",
                                "license",
                                "changelog",
                                "tests",
                                "core_entrypoints",
                            ],
                            "excluded_context": [
                                "Library",
                                ".soma",
                                "ProjectSettings",
                                "AutoSavedScene.unity",
                                "Assets/Plugins/Android",
                            ],
                            "expected_packet_style": "readiness_review_packet",
                            "confidence": 0.91,
                            "warnings": [],
                        }
                    )
                }
            }
            referee_response = {
                "message": {
                    "content": json.dumps(
                        {
                            "status": "ok",
                            "missing_evidence": [],
                            "bad_evidence": [],
                            "recommended_additions": [],
                            "warnings": [],
                        }
                    )
                }
            }
            graph_result = {
                "graphs": [str(root / ".soma" / "graphify-out" / "graph.json")],
                "answers": [{"graph": "wrapper", "answer": "Raw BFS mentions AutoSavedScene and Android icon noise."}],
                "warnings": [],
                "project_only": True,
            }

            with patch.object(llama, "query_ollama_model", new=AsyncMock(side_effect=[planner_response, referee_response])), patch(
                "scout_pipeline_module.pipeline._query_graphify_context",
                return_value=graph_result,
            ):
                bundle = self.run_gather(
                    "Prepare Nexus Unity for open source release. The current Unity root is only a wrapper test project; analyze package weak spots, strengths, docs, license, tests, and public entrypoints. Ignore APK icon and wrapper project settings.",
                    root,
                    "balanced",
                    False,
                    "deterministic",
                    "prompt_compiler",
                    "local",
                )

        packet = bundle["codex_packet"]
        focused_evidence = packet.split("Focused Evidence:", 1)[1].split("Expected answer:", 1)[0]
        evidence_paths = [item["path"].replace("\\", "/") for item in bundle["evidence_items"]]

        self.assertEqual(bundle["collection_plan_source"], "local_model")
        self.assertEqual(bundle["collection_plan"]["task_type"], "release_readiness")
        self.assertTrue(bundle["preflight"]["focus_root"].replace("\\", "/").endswith("/Assets/NexusUnity"))
        self.assertTrue(any(path.endswith("/Assets/NexusUnity/package.json") for path in evidence_paths))
        self.assertTrue(any(path.endswith("/Assets/NexusUnity/README.md") for path in evidence_paths))
        self.assertTrue(any(path.endswith("/Assets/NexusUnity/LICENSE.md") for path in evidence_paths))
        self.assertTrue(any(path.endswith("/Assets/NexusUnity/CHANGELOG.md") for path in evidence_paths))
        self.assertTrue(any(path.endswith("/Assets/NexusUnity/Editor/Tests/OpenSourceReadinessTests.cs") for path in evidence_paths))
        self.assertTrue(any(path.endswith("/Assets/NexusUnity/Editor/MCPServer.cs") for path in evidence_paths))
        self.assertIn("Collection Plan:", packet)
        self.assertIn("Focused Evidence:", packet)
        self.assertIn("Assets/NexusUnity/package.json", packet)
        self.assertNotIn("Git status:", packet)
        self.assertNotIn("Token budget:", packet)
        self.assertNotIn("Graph context (from Graphify):", packet)
        self.assertNotIn("Raw BFS", packet)
        self.assertFalse(any("AutoSavedScene.unity" in path for path in evidence_paths))
        self.assertFalse(any("ProjectSettings.asset" in path for path in evidence_paths))
        self.assertFalse(any("AndroidManifest.xml" in path for path in evidence_paths))
        self.assertNotIn("AutoSavedScene.unity", focused_evidence)
        self.assertNotIn("ProjectSettings.asset", focused_evidence)
        self.assertNotIn("AndroidManifest.xml", focused_evidence)
        self.assertFalse(bundle["evidence_quality"].get("excluded_context_selected"))

    def test_local_collection_planner_invalid_json_falls_back(self):
        tmp, root = self.make_repo()
        response = {"message": {"content": "not json"}}
        with tmp, patch.object(llama, "query_ollama_model", new=AsyncMock(return_value=response)):
            bundle = self.run_gather(
                "My jump broke and console has error on page 23.",
                root,
                "balanced",
                False,
                "deterministic",
                "prompt_compiler",
                "local",
            )

        self.assertEqual(bundle["collection_plan_source"], "deterministic_fallback")
        self.assertTrue(bundle["collection_plan_warnings"])
        self.assertEqual(bundle["collection_plan"]["task_type"], "debug")
        self.assertIn("logs", bundle["collection_plan"]["required_evidence"])
        self.assertTrue(any(stage["stage"] == "collection_plan" and stage["status"] == "failed" for stage in bundle["analysis_stages"]))

    def test_deterministic_collection_plan_requests_release_evidence(self):
        plan = scout_pipeline.deterministic_collection_plan(
            "Prepare Nexus Unity for open source release.",
            "/tmp/repo",
            "unity",
            {"package_manifests": [{"root": "/tmp/repo/Assets/NexusUnity", "displayName": "Nexus Unity"}]},
        )

        self.assertEqual(plan["task_type"], "release_readiness")
        self.assertEqual(plan["target_scope"], "unity_package")
        self.assertIn("package_manifest", plan["required_evidence"])
        self.assertIn("readme", plan["required_evidence"])
        self.assertIn("license", plan["required_evidence"])
        self.assertIn("tests", plan["required_evidence"])

    def test_plan_repair_adds_missing_required_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package_root = root / "Assets" / "NexusUnity"
            package_root.mkdir(parents=True)
            (root / "ProjectSettings").mkdir()
            (package_root / "README.md").write_text("# Nexus Unity\n")
            (package_root / "LICENSE.md").write_text("GPL-3.0-only\n")
            initial = [
                {
                    "path": str(package_root / "README.md"),
                    "kind": "notes",
                    "reason": "existing",
                    "preview": "# Nexus Unity",
                    "start_line": 1,
                    "end_line": 1,
                    "symbols": [],
                    "unity_refs": [],
                }
            ]
            repaired, additions = scout_pipeline.repair_evidence_from_plan(
                str(root),
                "Prepare Nexus Unity for open source.",
                "unity",
                initial,
                {"required_evidence": ["readme", "license"]},
                {"focus_root": str(package_root)},
                {"recommended_additions": ["license"]},
                {"files": []},
            )

        self.assertGreaterEqual(len(additions), 1)
        self.assertLessEqual(len(additions), 3)
        self.assertTrue(any(item["path"].endswith("LICENSE.md") for item in repaired))

    def test_prompt_compiler_excludes_generated_graphify_context(self):
        tmp, root = self.make_repo()
        graph_result = {
            "graphs": [str(root / "Library" / "PackageCache" / "graphify-out" / "graph.json")],
            "answers": [{"graph": "bad", "answer": "Graph context from generated dependency."}],
            "warnings": [],
            "project_only": True,
        }
        with tmp, patch("scout_pipeline_module.pipeline._query_graphify_context", return_value=graph_result):
            bundle = self.run_gather(
                "check relay diff",
                root,
                "balanced",
                False,
                "deterministic",
                "prompt_compiler",
                "off",
            )

        self.assertEqual(bundle["omitted_context"]["graphify"], "skipped")
        self.assertNotIn("Graph context (from Graphify):", bundle["codex_packet"])
        self.assertNotIn("generated dependency", bundle["codex_packet"])

    def test_catalog_files_are_not_misclassified_as_logs(self):
        self.assertIsNone(scout_pipeline.categorize_path("/repo/Library/Style.catalog"))

    def test_changed_files_outside_repo_index_are_added_to_evidence_candidates(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Assets" / "Plugins" / "Android").mkdir(parents=True)
            (root / "ProjectSettings").mkdir()
            project_settings = root / "ProjectSettings" / "ProjectSettings.asset"
            manifest = root / "Assets" / "Plugins" / "Android" / "AndroidManifest.xml"
            project_settings.write_text("PlayerSettings:\n")
            manifest.write_text("<manifest><application android:icon=\"@mipmap/app_icon\" /></manifest>\n")
            repo_index = {
                "files": [
                    {
                        "path": str(project_settings),
                        "category": "unity",
                        "mtime": 1,
                        "symbols": [],
                        "unity_refs": [],
                        "search_terms": [],
                    }
                ]
            }
            preflight = {
                "packet_mode": "review",
                "changed_paths": ["Assets/Plugins/Android/AndroidManifest.xml"],
                "explicit_paths": [],
                "error_paths": [],
            }
            evidence = scout_pipeline.select_evidence(
                str(root),
                "Investigate apk icon problem on Android.",
                "unity",
                repo_index,
                preflight,
            )

        self.assertTrue(any(item["path"].endswith("Assets/Plugins/Android/AndroidManifest.xml") for item in evidence))

    def test_review_prioritizes_changed_files_above_manifest_and_logs(self):
        tmp, root = self.make_repo()
        with tmp:
            bundle = self.run_gather("do we have bugs?", root, "balanced", False)

        paths = [Path(item["path"]).name for item in bundle["evidence_items"][:3]]
        # When Go daemon is unavailable, evidence may be empty; skip ordering check
        if paths:
            self.assertNotEqual(paths[0], "Package.swift")
            self.assertNotEqual(paths[0], "ollama_logs.txt")

    def test_noise_files_are_omitted(self):
        tmp, root = self.make_repo()
        with tmp:
            subprocess.run(["git", "add", ".DS_Store", "Soma/__pycache__/relay.cpython-313.pyc"], cwd=root, check=True)
            bundle = self.run_gather("what changed", root, "balanced", False)

        packet = bundle["codex_packet"]
        # git_diff_summary may be None if Go daemon is unavailable
        changed_paths = []
        if bundle["git_diff_summary"] is not None:
            changed_paths = [item["path"] for item in (bundle["git_diff_summary"].get("changed_files") or [])]
        evidence_paths = [item["path"] for item in bundle["evidence_items"]]
        self.assertFalse(any(".DS_Store" in path for path in changed_paths + evidence_paths))
        self.assertFalse(any("__pycache__" in path or path.endswith(".pyc") for path in changed_paths + evidence_paths))
        self.assertNotIn(".DS_Store", packet)
        self.assertNotIn("__pycache__", packet)

    def test_unity_package_cache_is_deprioritized_without_explicit_reference(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Assets" / "Scripts").mkdir(parents=True)
            (root / "ProjectSettings").mkdir()
            (root / "Library" / "PackageCache" / "com.unity.timeline").mkdir(parents=True)
            (root / "Assets" / "Scripts" / "NexusBridge.cs").write_text("public class NexusBridge { void CompileRuntime() {} }\n")
            (root / "ProjectSettings" / "ProjectSettings.asset").write_text("m_Name: UnityTest\n")
            package_file = root / "Library" / "PackageCache" / "com.unity.timeline" / "RuntimeTrack.cs"
            package_file.write_text("public class RuntimeTrack { void CompileRuntime() {} }\n")

            discovered = scout_pipeline.iter_project_files(str(root))
            repo_index = scout_pipeline.build_repo_index(str(root), discovered)
            preflight = scout_pipeline.build_preflight("review compile runtime NexusBridge", str(root), "unity", discovered, repo_index, "", {})
            evidence = scout_pipeline.select_evidence(str(root), "review compile runtime NexusBridge", "unity", repo_index, preflight)
            paths = [item["path"] for item in evidence]

        self.assertTrue(any(path.endswith("Assets/Scripts/NexusBridge.cs") for path in paths))
        self.assertFalse(any("Library/PackageCache" in path for path in paths[:3]))

    def test_explicit_package_cache_reference_can_still_be_selected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Assets").mkdir()
            (root / "ProjectSettings").mkdir()
            (root / "Library" / "PackageCache" / "com.unity.timeline").mkdir(parents=True)
            package_file = root / "Library" / "PackageCache" / "com.unity.timeline" / "RuntimeTrack.cs"
            package_file.write_text("public class RuntimeTrack {}\n")

            discovered = scout_pipeline.iter_project_files(str(root))
            repo_index = scout_pipeline.build_repo_index(str(root), discovered)
            prompt = "inspect `Library/PackageCache/com.unity.timeline/RuntimeTrack.cs`"
            explicit = scout_pipeline.gather_external_evidence(prompt, str(root), ["runtime"], discovered, repo_index)

        self.assertTrue(any(item["path"].endswith("Library/PackageCache/com.unity.timeline/RuntimeTrack.cs") for item in explicit))

    def test_ranker_failure_does_not_block_packet(self):
        tmp, root = self.make_repo()
        with tmp, patch("scout_pipeline.query_ollama_model", new=AsyncMock(return_value={"error": "offline"})):
            bundle = self.run_gather("do we have bugs?", root, "balanced", False, "ranked")

        self.assertEqual(bundle["analysis_depth"], "ranked")
        self.assertTrue(bundle["codex_packet"])
        self.assertEqual(bundle["analysis_stages"][-1]["stage"], "ranker")
        # Status is 'failed' when ranker receives error, 'skipped' when no evidence to rank
        self.assertIn(bundle["analysis_stages"][-1]["status"], {"failed", "skipped"})

    def test_openai_cloud_referee_uses_compact_metadata_only(self):
        response = FakeHTTPResponse(
            json.dumps(
                {
                    "output_text": json.dumps(
                        {
                            "status": "degraded",
                            "missing_evidence": ["changelog"],
                            "recommended_additions": ["graphify --version"],
                            "warnings": ["Missing version evidence."],
                            "notes": ["Ask for the exact installed graph version."],
                        }
                    )
                }
            )
        )
        with patch.dict(
            os.environ,
            {
                "SOMA_CLOUD_REFEREE_PROVIDER": "openai",
                "SOMA_OPENAI_API_KEY": "test-key",
                "SOMA_OPENAI_REFEREE_MODEL": "gpt-test-referee",
                "SOMA_CLOUD_REFEREE_POLICY": "always",
            },
        ), patch(
            "scout_pipeline_module.cloud_referee.urllib.request.urlopen",
            return_value=response,
        ) as urlopen:
            result, stage = asyncio.run(
                scout_pipeline.referee_evidence_with_cloud_model(
                    "Review graph version and changelog.",
                    {"required_evidence": ["changelog", "version"]},
                    {"packet_mode": "review"},
                    [
                        {
                            "path": "/repo/Soma/gateway/graphify_adapter.py",
                            "kind": "source",
                            "reason": "Graph integration",
                            "preview": "SECRET_SOURCE_BODY",
                            "symbols": ["GraphifyAdapter"],
                        }
                    ],
                    {"status": "ok"},
                )
            )

        request = urlopen.call_args.args[0]
        body = json.loads(request.data.decode("utf-8"))
        payload = json.loads(body["input"][1]["content"])
        self.assertEqual(body["model"], "gpt-test-referee")
        self.assertEqual(stage["status"], "ok")
        self.assertEqual(result["status"], "degraded")
        self.assertIn("changelog", result["missing_evidence"])
        self.assertNotIn("SECRET_SOURCE_BODY", json.dumps(payload))
        self.assertEqual(payload["selected_evidence"][0]["path"], "/repo/Soma/gateway/graphify_adapter.py")

    def test_cloud_referee_policy_defaults_to_degraded_only(self):
        with patch.dict(
            os.environ,
            {
                "SOMA_CLOUD_REFEREE_PROVIDER": "openai",
                "SOMA_OPENAI_API_KEY": "test-key",
            },
            clear=False,
        ):
            self.assertFalse(scout_pipeline.cloud_referee_should_run({"status": "ok", "plan_alignment_status": "ok"}))
            self.assertTrue(scout_pipeline.cloud_referee_should_run({"status": "degraded", "plan_alignment_status": "ok"}))
            self.assertTrue(scout_pipeline.cloud_referee_should_run({"status": "ok", "missing_required_evidence": ["changelog"]}))

    def test_cloud_referee_can_degrade_packet_without_blocking_generation(self):
        tmp, root = self.make_repo()
        response = FakeHTTPResponse(
            json.dumps(
                {
                    "output_text": json.dumps(
                        {
                            "status": "degraded",
                            "missing_evidence": ["All available changelogs"],
                            "recommended_additions": ["graphify --version"],
                            "warnings": [],
                            "notes": [],
                        }
                    )
                }
            )
        )
        with tmp, patch.dict(
            os.environ,
            {
                "SOMA_CLOUD_REFEREE_PROVIDER": "openai",
                "SOMA_OPENAI_API_KEY": "test-key",
                "SOMA_OPENAI_REFEREE_MODEL": "gpt-test-referee",
                "SOMA_CLOUD_REFEREE_POLICY": "always",
            },
        ), patch(
            "scout_pipeline_module.cloud_referee.urllib.request.urlopen",
            return_value=response,
        ):
            bundle = self.run_gather("Review graph version and all changelogs.", root, "balanced", False)

        self.assertTrue(bundle["codex_packet"])
        self.assertEqual(bundle["status"], "degraded")
        self.assertTrue(any(stage["stage"] == "cloud_referee" and stage["status"] == "ok" for stage in bundle["analysis_stages"]))
        self.assertIn("All available changelogs", bundle["evidence_quality"].get("referee_missing_context", []))

    def test_ollama_query_logs_local_model_usage_without_raw_prompt(self):
        response = FakeHTTPResponse(json.dumps({"message": {"content": "{\"ordered_ids\":[0]}"}}))
        with tempfile.TemporaryDirectory() as log_tmp, patch.object(
            llama.urllib.request, "urlopen", return_value=response
        ), patch.object(
            soma_logger, "SOMA_LOG_DIR", Path(log_tmp)
        ), patch.object(
            soma_logger, "SOMA_SESSION_STATS_FILE", Path(log_tmp) / "session_stats.json"
        ):
            result = asyncio.run(
                llama.query_ollama_model(
                    "gemma4:e4b",
                    [{"role": "user", "content": "SECRET_PROMPT"}],
                    json_mode=True,
                    stage="ranker",
                )
            )
            log_text = "\n".join(path.read_text() for path in Path(log_tmp).glob("soma_*.jsonl"))

        self.assertIn("message", result)
        self.assertIn("local_model_call", log_text)
        self.assertIn('"local_model_stage": "ranker"', log_text)
        self.assertIn('"local_model": "gemma4:e4b"', log_text)
        self.assertNotIn("SECRET_PROMPT", log_text)


if __name__ == "__main__":
    unittest.main()

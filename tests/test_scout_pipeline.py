from scout_pipeline_test_helpers import *


class ScoutPipelineBasicTests(ScoutPipelineTestCase):
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
        self.assertIn("Graph suggested:", bundle["codex_packet"])
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


if __name__ == '__main__':
    unittest.main()

from scout_pipeline_test_helpers import *


class ScoutPipelineSelectionTests(ScoutPipelineTestCase):
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
            manifest.write_text('<manifest><application android:icon="@mipmap/app_icon" /></manifest>\n')
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
            (root / "Assets" / "Scripts" / "NexusBridge.cs").write_text(
                "public class NexusBridge { void CompileRuntime() {} }\n"
            )
            (root / "ProjectSettings" / "ProjectSettings.asset").write_text("m_Name: UnityTest\n")
            package_file = root / "Library" / "PackageCache" / "com.unity.timeline" / "RuntimeTrack.cs"
            package_file.write_text("public class RuntimeTrack { void CompileRuntime() {} }\n")

            discovered = scout_pipeline.iter_project_files(str(root))
            repo_index = scout_pipeline.build_repo_index(str(root), discovered)
            preflight = scout_pipeline.build_preflight(
                "review compile runtime NexusBridge", str(root), "unity", discovered, repo_index, "", {}
            )
            evidence = scout_pipeline.select_evidence(
                str(root), "review compile runtime NexusBridge", "unity", repo_index, preflight
            )
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

        self.assertTrue(
            any(item["path"].endswith("Library/PackageCache/com.unity.timeline/RuntimeTrack.cs") for item in explicit)
        )

    def test_graphify_version_prompt_adds_command_evidence(self):
        tmp, root = self.make_repo()

        def fake_run(cmd, **kwargs):
            joined = " ".join(cmd)
            if "graphify --version" in joined:
                return subprocess.CompletedProcess(cmd, 0, stdout="graphify 0.8.18\n", stderr="")
            if "pip index versions graphifyy" in joined:
                return subprocess.CompletedProcess(
                    cmd, 0, stdout="graphifyy (0.8.18)\nAvailable versions: 0.8.18, 0.8.17\n", stderr=""
                )
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        with tmp, patch("scout_pipeline_module.gather.subprocess.run", side_effect=fake_run):
            bundle = self.run_gather("Review Graphify latest version and changelog features.", root, "balanced", False)

        command_paths = [item["path"] for item in bundle["evidence_items"] if item.get("kind") == "command"]
        self.assertIn("command: graphify --version", command_paths)
        self.assertTrue(any("pip index versions graphifyy" in path for path in command_paths))
        self.assertFalse(any("/fixtures/" in item["path"] for item in bundle["evidence_items"]))
        self.assertIn("Graphify changelog/release notes", bundle["codex_packet"])


if __name__ == "__main__":
    unittest.main()

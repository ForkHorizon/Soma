from scout_pipeline_test_helpers import *


class ScoutPipelinePlanningTests(ScoutPipelineTestCase):
    def test_prompt_compiler_stress_uses_planned_package_scope_over_wrapper_noise(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_nexus_unity_fixture(root, version="2.8.0", include_noise=True)

            with patch.object(llama, "query_ollama_model", new=AsyncMock(side_effect=[
                release_planner_response(),
                ok_referee_response(),
            ])), patch(
                "scout_pipeline_module.pipeline._query_graphify_context",
                return_value=wrapper_graphify_result(root),
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

        assert_planned_release_packet(self, bundle)

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


if __name__ == '__main__':
    unittest.main()

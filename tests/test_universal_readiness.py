from universal_readiness_helpers import *


class UniversalReadinessScoutTests(UniversalReadinessTestCase):
    def test_fixture_templates_cover_known_project_types(self):
        names = {path.name for path in fixture_templates(FIXTURES)}
        self.assertTrue(set(EXPECTED_TYPES).issubset(names))

    def test_project_detection_for_all_fixture_types(self):
        for template in fixture_templates(FIXTURES):
            with self.subTest(template=template.name):
                detected, _ = detect_project_type(str(template))
                self.assertEqual(detected, EXPECTED_TYPES[template.name])

    def test_scanner_fallback_indexes_and_filters_all_fixtures(self):
        for template in fixture_templates(FIXTURES):
            with self.subTest(template=template.name):
                files = iter_project_files(str(template))
                self.assertTrue(files)
                names = [item["name"] for item in files]
                self.assertFalse(any(name == ".DS_Store" for name in names))
                self.assertTrue(any(item["category"] in {"source", "script"} for item in files))

    def test_prepare_context_for_each_fixture_is_budgeted_and_relevant(self):
        for template in fixture_templates(FIXTURES):
            with self.subTest(template=template.name):
                tmp, root = prepare_fixture_repo(template)
                with tmp, patch.object(gateway.core.graphify, "query", return_value={"graphs": [], "answers": [], "warnings": []}):
                    os.environ["SOMA_PROJECT_ROOT"] = str(root)
                    payload = json.loads(asyncio.run(gateway.tools.context.soma_prepare_context(
                        f"Debug recent changed behavior in {template.name}; check source, git, config, and logs.",
                        "fast",
                        "deterministic",
                    )))
                self.assertEqual(payload["status"], "ok")
                self.assertTrue(payload["packet"])
                self.assertLessEqual(payload["estimated_tokens"], TOKEN_BUDGETS["fast"])
                self.assertEqual(payload["token_savings"]["primary_metric"], "operation_savings")
                self.assertIn(payload["operation_savings"]["status"], {"ok", "degraded"})
                self.assertEqual(payload["estimated_context_reduction"]["status"], "ok")
                self.assertGreater(payload["estimated_context_reduction"]["saved_tokens"], 0)
                self.assertTrue(payload["evidence"])
                self.assertNotIn("diff --git", payload["packet"])
                self.assertNotIn(".DS_Store", payload["packet"])
                self.assertNotIn("__pycache__", payload["packet"])

    def test_evidence_quality_for_debug_and_changes(self):
        template = FIXTURES / "python_package"
        tmp, root = prepare_fixture_repo(template)
        with tmp:
            project_type, _ = detect_project_type(str(root))
            git_status = get_git_status(str(root))
            diff = get_git_diff_summary(str(root), ["debug"])
            discovered = iter_project_files(str(root))
            index = build_repo_index(str(root), discovered)
            preflight = build_preflight("debug changed app error", str(root), project_type, discovered, index, git_status, diff)
            evidence = select_evidence(str(root), "debug changed app error", project_type, index, preflight)

        self.assertTrue(evidence)
        self.assertTrue(any(item["kind"] == "log" for item in evidence))
        self.assertTrue(any(item["kind"] == "source" for item in evidence))
        self.assertGreater((diff or {}).get("raw_diff_chars_omitted", 0), 0)

    def test_quiet_hours_packet_selects_real_case_chain_without_cross_graph(self):
        tmp, root = make_quiet_hours_repo()
        prompt = (
            "Read-only analysis. Investigate whether Moodling quiet hours can fail when "
            "the quiet interval crosses midnight. Return likely root cause, exact files to inspect, "
            "test cases that should exist, and a minimal fix plan."
        )
        with tmp, patch.object(gateway.core.graphify, "query", return_value={"graphs": [], "answers": [], "warnings": []}):
            os.environ["SOMA_PROJECT_ROOT"] = str(root)
            payload = json.loads(asyncio.run(gateway.tools.context.soma_prepare_context(prompt, "fast", "deterministic")))

        packet = payload["packet"]
        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["omitted"]["graphify"], "skipped")
        for expected in [
            "CooldownPolicy.swift",
            "NudgeScheduler.swift",
            "AppState.swift",
            "MoodlingSettings.swift",
            "SettingsView.swift",
            "CooldownPolicyTests.swift",
            "docs/behavior.md",
            "quiet_hours_cross_midnight.jsonl",
        ]:
            self.assertIn(expected, packet)
        self.assertIn("return currentMinute >= start || currentMinute < end", packet)
        self.assertNotIn("UnityTestForNexus", packet)

    def test_prepare_context_degrades_when_no_strong_evidence_matches(self):
        tmp, root = make_quiet_hours_repo()
        with tmp, patch.object(gateway.core.graphify, "query", return_value={"graphs": [], "answers": [], "warnings": []}):
            os.environ["SOMA_PROJECT_ROOT"] = str(root)
            payload = json.loads(asyncio.run(gateway.tools.context.soma_prepare_context("Debug phantom zyxwvu crash", "fast", "deterministic")))

        self.assertEqual(payload["status"], "degraded")
        self.assertEqual(payload["evidence_quality"]["status"], "degraded")


if __name__ == '__main__':
    unittest.main()

from universal_readiness_helpers import *


class TokenAndUniversalCLITests(unittest.TestCase):
    def test_token_calculator_profiles_are_deterministic(self):
        self.assertEqual(profile_for("GPT-5.5").key, "gpt-5.5")
        self.assertGreater(estimate_tokens("abcd" * 100, "gpt-5.5"), 1)
        payload = estimate_payload("abcd" * 10, "claude")
        self.assertEqual(payload["model_profile"], "claude")
        self.assertIn(payload["estimator"], {"tiktoken", "chars_per_token"})

    def test_token_calculator_falls_back_when_exact_encoder_unavailable(self):
        with patch.object(token_calculator, "_encoding_for", return_value=None):
            payload = estimate_payload("abcd" * 100, "gpt-5.5")
        self.assertEqual(payload["estimator"], "chars_per_token")
        self.assertGreater(payload["estimated_tokens"], 0)

    def test_rus_to_prompt_script_entrypoint_resolves_facade_api(self):
        script = Path(__file__).resolve().parents[1] / "Soma" / "soma_language_optimizer.py"
        completed = subprocess.run(
            [sys.executable, str(script), "--rus-to-prompt-translate", "--translator-model", "unused-local-model", "Check this."],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        payload = json.loads(completed.stdout)
        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["translation_status"], "original_english")
        self.assertEqual(payload["translation"], "Check this.")

    def test_token_savings_unavailable_for_failed_packet(self):
        savings = build_token_savings(
            packet="",
            budget="fast",
            budget_tokens=TOKEN_BUDGETS["fast"],
            model_profile="gpt-5.5",
            status="error",
        )
        self.assertEqual(savings["status"], "unavailable")
        self.assertIsNone(savings["savings_pct"])

    def test_operation_savings_stores_counts_hashes_not_raw_bodies(self):
        template = FIXTURES / "python_package"
        tmp, root = prepare_fixture_repo(template)
        with tmp:
            secret = "SOMA_SECRET_SHOULD_NOT_APPEAR"
            source = root / "src" / "python_fixture" / "app.py"
            source.write_text(source.read_text() + f"\n# {secret}\n", encoding="utf-8")
            result = build_operation_savings(
                packet="Compact Soma packet",
                project_root=str(root),
                git_status=" M src/sample_pkg/core.py",
                evidence_items=[{"path": str(source), "kind": "source"}],
                budget="fast",
                budget_tokens=TOKEN_BUDGETS["fast"],
                model_profile="gpt-5.5",
            )
        rendered = json.dumps(result)
        self.assertIn("operations", result)
        self.assertNotIn(secret, rendered)
        self.assertIn("sha256", rendered)
        self.assertGreater(result["operation_baseline_tokens"], 0)

    def test_agent_usage_extractor_handles_cli_usage_and_fallback(self):
        stdout = "\n".join([
            json.dumps({"event": "started"}),
            json.dumps({"usage": {"input_tokens": 120, "output_tokens": 30, "total_tokens": 150}}),
        ])
        usage = soma_agent_ab_benchmark.extract_usage_from_events(stdout)
        self.assertEqual(usage["usage_source"], "cli_event")
        self.assertEqual(usage["total_tokens"], 150)
        self.assertIsNone(soma_agent_ab_benchmark.extract_usage_from_events("plain transcript"))

    def test_agent_command_supports_hermes_with_file_terminal_tools(self):
        args, cwd = soma_agent_ab_benchmark._agent_command("hermes", "Check quiet hours", Path("/tmp/project"), None, True)
        self.assertEqual(cwd, Path("/tmp/project"))
        self.assertEqual(args[:3], ["hermes", "--toolsets", "file,terminal"])
        self.assertIn("-z", args)
        self.assertEqual(soma_agent_ab_benchmark._redacted_command(args)[-1], "<prompt>")

    def test_hermes_moodling_scenario_fixture_loads_relative_project(self):
        scenario = soma_agent_ab_benchmark._load_scenario(
            str(Path(__file__).resolve().parent / "fixtures" / "agent_scenarios" / "moodling_quiet_hours_hermes.json")
        )
        task = scenario["tasks"][0]

        self.assertEqual(scenario["agents"], ["hermes"])
        self.assertTrue(Path(scenario["project_root"]).is_dir())
        self.assertTrue(str(scenario["project_root"]).endswith("moodling_quiet_hours"))
        self.assertIn("QuietHoursManager.swift", task["must_not_mention_files"])
        self.assertIn("CooldownPolicy.swift", task["expected_files"])

    def test_agent_acceptance_rubric_uses_hash_safe_transcript_scan(self):
        task = {
            "expected_files": ["CooldownPolicy.swift"],
            "must_mention": ["midnight"],
            "must_not_claim": ["delete settings"],
            "must_not_mention_files": ["QuietHoursManager.swift", "Configuration.swift"],
        }
        passed = soma_agent_ab_benchmark._evaluate_acceptance(task, "Check CooldownPolicy.swift around midnight.", "", "ok")
        failed = soma_agent_ab_benchmark._evaluate_acceptance(
            task,
            "Check SettingsView.swift and QuietHoursManager.swift.",
            "delete settings Configuration.swift",
            "ok",
        )
        self.assertEqual(passed["status"], "passed")
        self.assertEqual(failed["status"], "failed")
        self.assertIn("CooldownPolicy.swift", failed["expected_files_missing"])
        self.assertIn("QuietHoursManager.swift", failed["must_not_claim_found"])
        self.assertIn("Configuration.swift", failed["must_not_claim_found"])

    def test_agent_ab_summary_does_not_fake_failed_savings(self):
        runs = [
            {"task_id": "debug", "agent": "codex", "mode": "direct", "status": "ok", "total_tokens": 1000, "acceptance_status": "manual_review_required"},
            {"task_id": "debug", "agent": "codex", "mode": "with_soma", "status": "error", "total_tokens": 100, "acceptance_status": "not_applicable", "soma_packet_status": "degraded"},
        ]
        comparisons = soma_agent_ab_benchmark._compare_pairs(runs)
        summary = soma_agent_ab_benchmark._build_summary(runs, comparisons)
        self.assertEqual(comparisons[0]["status"], "unavailable")
        self.assertEqual(summary["paired_result_count"], 0)
        self.assertIsNone(summary["avg_savings_pct"])

    def test_universal_report_saves_core_fields_with_mocked_fixture_result(self):
        fake = {
            "fixture": "python_package",
            "status": "ok",
            "calls": {"soma_prepare_context": {"status": "ok"}},
        }
        with patch.object(universal, "fixture_templates", return_value=[FIXTURES / "python_package"]), patch.object(
            universal, "_verify_fixture", return_value=fake
        ), patch.object(universal, "_ollama_health", return_value={"status": "offline"}), patch.object(
            sys, "argv", ["verify_soma_universal_workflow.py"]
        ), tempfile.TemporaryDirectory() as tmp:
            with patch.dict(os.environ, {"HOME": tmp}):
                rc = universal.main()
                latest = Path(tmp) / ".soma" / "acceptance" / "universal" / "latest.json"
                report = json.loads(latest.read_text())

        self.assertEqual(rc, 0)
        self.assertEqual(report["core_status"], "ok")
        self.assertEqual(report["plugin_status"]["unity_nexus"], "skipped")

    def test_token_benchmark_writes_stats_with_mocked_result(self):
        fake_result = {
            "fixture": "python_package",
            "status": "ok",
            "baseline_tokens": 1000,
            "soma_packet_tokens": 200,
            "saved_tokens": 800,
            "savings_pct": 80.0,
            "budget": "fast",
            "model_profile": "gpt-5.5",
            "project_type": "python",
            "raw_repo_tokens": 700,
            "raw_git_tokens": 300,
            "estimated_tokens_reported": 200,
            "omitted": {},
        }
        with patch.object(soma_token_benchmark, "fixture_templates", return_value=[FIXTURES / "python_package"]), patch.object(
            soma_token_benchmark, "_benchmark_fixture", return_value=fake_result
        ), patch.object(sys, "argv", ["soma_token_benchmark.py"]), tempfile.TemporaryDirectory() as tmp:
            with patch.dict(os.environ, {"HOME": tmp}):
                rc = soma_token_benchmark.main()
                stats = json.loads((Path(tmp) / ".soma" / "token_stats.json").read_text())

        self.assertEqual(rc, 0)
        self.assertEqual(stats["summary"]["avg_savings_pct"], 80.0)
        self.assertEqual(stats["summary"]["total_saved_tokens"], 800)

    def test_token_benchmark_summary_excludes_failed_results(self):
        summary = soma_token_benchmark._build_summary(
            [
                {"fixture": "ok", "status": "ok", "baseline_tokens": 1000, "soma_packet_tokens": 200, "saved_tokens": 800, "savings_pct": 80.0},
                {"fixture": "bad", "status": "error", "baseline_tokens": None, "soma_packet_tokens": None, "saved_tokens": None, "savings_pct": None},
            ],
            "fixtures",
        )
        self.assertEqual(summary["avg_savings_pct"], 80.0)
        self.assertEqual(summary["failed_fixture_count"], 1)
        self.assertEqual(summary["valid_result_count"], 1)

    def test_analytics_aggregates_local_model_usage(self):
        with tempfile.TemporaryDirectory() as tmp:
            log_dir = Path(tmp) / "logs"
            analytics_dir = Path(tmp) / "analytics"
            log_dir.mkdir()
            log_file = log_dir / "soma_20260515.jsonl"
            entries = [
                {
                    "ts": "2026-05-15T12:00:00+00:00",
                    "event": "local_model_call",
                    "status": "ok",
                    "duration_ms": 120.0,
                    "input_tokens": 40,
                    "output_tokens": 10,
                    "local_model_provider": "ollama",
                    "local_model": "gemma4:e4b",
                    "local_model_stage": "ranker",
                },
                {
                    "ts": "2026-05-15T12:00:01+00:00",
                    "event": "local_model_call",
                    "status": "error",
                    "duration_ms": 30.0,
                    "input_tokens": 20,
                    "output_tokens": 0,
                    "local_model_provider": "ollama",
                    "local_model": "qwen3-coder:30b-a3b-q4_K_M",
                    "local_model_stage": "analyst",
                },
                {
                    "ts": "2026-05-15T12:00:02+00:00",
                    "event": "mcp_request",
                    "method": "tools/list",
                    "status": "ok",
                },
            ]
            log_file.write_text("\n".join(json.dumps(entry) for entry in entries), encoding="utf-8")
            with patch.object(soma_analytics, "SOMA_LOG_DIR", log_dir), patch.object(
                soma_analytics, "SOMA_ANALYTICS_DIR", analytics_dir
            ):
                report = soma_analytics.compute_report("20260515")

        self.assertEqual(report["summary"]["local_model_call_count"], 2)
        self.assertEqual(report["summary"]["local_model_error_count"], 1)
        self.assertEqual(report["summary"]["local_model_total_tokens"], 70)
        self.assertEqual(report["summary"]["mcp_tools_list_count"], 1)
        self.assertEqual(report["summary"]["soma_tool_call_count"], 0)
        self.assertIn("mcp_discovered_but_no_soma_tool_calls", report["mcp_usage_health"]["warnings"])
        self.assertEqual(report["local_model_usage"]["by_stage"]["ranker"]["calls"], 1)
        self.assertEqual(report["local_model_usage"]["by_model"]["gemma4:e4b"]["calls"], 1)


if __name__ == "__main__":
    unittest.main()

if __name__ == '__main__':
    unittest.main()

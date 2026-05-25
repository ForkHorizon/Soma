import asyncio
import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Soma"))
from soma_test_bootstrap import install_soma_imports
install_soma_imports()

from scout_pipeline import TOKEN_BUDGETS
from scout_pipeline_module.discovery import build_repo_index, detect_project_type, iter_project_files
from scout_pipeline_module.gather import assess_evidence_quality, build_preflight, select_evidence
from scout_pipeline_module.git import get_git_diff_summary, get_git_status
import token_calculator
from soma_token_savings import build_operation_savings, build_token_savings
from token_calculator import estimate_payload, estimate_tokens, profile_for
from universal_fixtures import fixture_templates, prepare_fixture_repo

import gateway.core
import gateway.tool_registry
import gateway.tools.context
import verify_soma_universal_workflow as universal
import soma_token_benchmark
import soma_agent_ab_benchmark
import soma_language_optimizer
import soma_audit
import soma_analytics


FIXTURES = Path(__file__).resolve().parent / "fixtures" / "projects"


EXPECTED_TYPES = {
    "swift_app": "swift",
    "python_package": "python",
    "node_ts_app": "javascript",
    "go_cli": "go",
    "rust_crate": "rust",
    "cpp_project": "cpp",
    "java_kotlin_project": "java_kotlin",
    "script_repo": "unknown",
    "generic_mixed_repo": "php",
    "php_project": "php",
    "ruby_project": "ruby",
}


def make_quiet_hours_repo():
    tmp = tempfile.TemporaryDirectory()
    root = Path(tmp.name)
    (root / "Moodling" / "Core").mkdir(parents=True)
    (root / "Moodling" / "Models").mkdir(parents=True)
    (root / "Moodling" / "Views").mkdir(parents=True)
    (root / "MoodlingTests").mkdir()
    (root / "docs").mkdir()
    (root / "fixtures" / "system_events").mkdir(parents=True)
    (root / "Package.swift").write_text("// swift-tools-version: 5.9\n", encoding="utf-8")
    (root / "Moodling" / "Core" / "CooldownPolicy.swift").write_text(
        "import Foundation\nstruct CooldownPolicy {\n"
        "func isQuietTime(currentMinute: Int, start: Int, end: Int) -> Bool {\n"
        "if start == end { return true }\n"
        "if start < end { return currentMinute >= start && currentMinute < end }\n"
        "return currentMinute >= start || currentMinute < end\n}\n}\n",
        encoding="utf-8",
    )
    (root / "Moodling" / "Core" / "NudgeScheduler.swift").write_text(
        "struct NudgeScheduler { let cooldownPolicy = CooldownPolicy() }\n",
        encoding="utf-8",
    )
    (root / "Moodling" / "AppState.swift").write_text(
        "final class AppState { let nudgeScheduler = NudgeScheduler(); func testNudge() {} }\n",
        encoding="utf-8",
    )
    (root / "Moodling" / "Models" / "MoodlingSettings.swift").write_text(
        "struct MoodlingSettings { var quietHoursEnabled = true; var quietHoursStartMinutes = 23 * 60; var quietHoursEndMinutes = 8 * 60 }\n",
        encoding="utf-8",
    )
    (root / "Moodling" / "Views" / "SettingsView.swift").write_text(
        "struct SettingsView { let label = \"Quiet hours\" }\n",
        encoding="utf-8",
    )
    (root / "MoodlingTests" / "CooldownPolicyTests.swift").write_text(
        "import XCTest\nfinal class CooldownPolicyTests: XCTestCase { func testQuietHoursCrossMidnight() {} }\n",
        encoding="utf-8",
    )
    (root / "docs" / "behavior.md").write_text(
        "# Behavior\nQuiet hours suppress nudges and bubbles between start and end, including midnight crossing intervals.\n",
        encoding="utf-8",
    )
    (root / "fixtures" / "system_events" / "quiet_hours_cross_midnight.jsonl").write_text(
        "{\"type\":\"manual_nudge\",\"expected\":\"allowed_before_quiet_hours\"}\n"
        "{\"type\":\"agent_log\",\"expected\":\"suppressed_after_midnight\"}\n",
        encoding="utf-8",
    )
    subprocess.run(["git", "init"], cwd=root, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
    subprocess.run(["git", "add", "."], cwd=root, check=True)
    subprocess.run(["git", "commit", "-m", "init"], cwd=root, check=True, capture_output=True)
    return tmp, root


class UniversalReadinessTests(unittest.TestCase):
    def setUp(self):
        self.previous_root = os.environ.get("SOMA_PROJECT_ROOT")

    def tearDown(self):
        if self.previous_root is None:
            os.environ.pop("SOMA_PROJECT_ROOT", None)
        else:
            os.environ["SOMA_PROJECT_ROOT"] = self.previous_root

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

    def test_language_optimizer_translates_russian_and_preserves_protected_spans(self):
        prompt = (
            "Проверь `CooldownPolicy.swift`, /tmp/project/docs/behavior.md и https://example.com/quiet. "
            "Не меняй JSON {\"mode\":\"quiet\",\"after\":\"00:00\"}. "
            "Код:\n```swift\nlet policy = CooldownPolicy()\n```\n"
            "Запусти rg quiet и верни план."
        )

        def fake_translate(text, model, timeout):
            placeholders = re.findall(r"SOMAPROTECTED\d+", text)
            self.assertGreaterEqual(len(placeholders), 5)
            return "Check " + ", ".join(placeholders) + ". Run rg quiet and return a plan."

        with patch.object(soma_language_optimizer, "_local_ollama_translate", side_effect=fake_translate):
            normalized, metadata = soma_language_optimizer.optimize_prompt_language(prompt, "gpt-5.5")

        self.assertEqual(metadata["status"], "translated")
        self.assertEqual(metadata["source_language"], "ru")
        self.assertIn("`CooldownPolicy.swift`", normalized)
        self.assertIn("/tmp/project/docs/behavior.md", normalized)
        self.assertIn("https://example.com/quiet", normalized)
        self.assertIn("{\"mode\":\"quiet\",\"after\":\"00:00\"}", normalized)
        self.assertIn("```swift\nlet policy = CooldownPolicy()\n```", normalized)
        self.assertIn("rg quiet", normalized)
        self.assertGreater(metadata["protected_spans_count"], 0)
        self.assertNotIn("Проверь", normalized)

    def test_language_optimizer_fallback_does_not_block(self):
        prompt = "Проверь тихие часы и верни план."
        with patch.object(soma_language_optimizer, "_local_ollama_translate", side_effect=RuntimeError("offline")):
            normalized, metadata = soma_language_optimizer.optimize_prompt_language(prompt, "gpt-5.5")

        self.assertEqual(normalized, prompt)
        self.assertEqual(metadata["status"], "failed_fallback")
        self.assertEqual(metadata["source_language"], "ru")

    def test_russian_quiet_hours_prompt_uses_english_packet_without_original_prompt(self):
        tmp, root = make_quiet_hours_repo()
        prompt = (
            "Проверь, может ли Moodling quiet hours ломаться, когда интервал пересекает полночь. "
            "Верни причину, точные файлы, тесты и минимальный план исправления."
        )

        def fake_translate(text, model, timeout):
            return (
                "Investigate whether Moodling quiet hours can fail when the quiet interval crosses midnight. "
                "Return likely root cause, exact files, tests, and minimal fix plan."
            )

        with tmp, patch.object(gateway.core.graphify, "query", return_value={"graphs": [], "answers": [], "warnings": []}), patch.object(
            soma_language_optimizer, "_local_ollama_translate", side_effect=fake_translate
        ), patch.dict(os.environ, {"SOMA_PROJECT_ROOT": str(root), "SOMA_TRANSLATION_ENABLED": "1", "SOMA_TRANSLATION_PROVIDER": "local"}):
            payload = json.loads(asyncio.run(gateway.tools.context.soma_prepare_context(prompt, "fast", "deterministic")))

        packet = payload["packet"]
        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["language_optimization"]["status"], "translated")
        self.assertEqual(payload["language_optimization"]["source_language"], "ru")
        self.assertIn("Expected answer language: English", packet)
        self.assertIn("Original language: ru", packet)
        self.assertNotIn("Проверь", packet)
        for expected in ["CooldownPolicy.swift", "NudgeScheduler.swift", "AppState.swift", "MoodlingSettings.swift"]:
            self.assertIn(expected, packet)

    def test_audit_report_metadata_only_by_default_and_tracks_missing_evidence(self):
        tmp, root = make_quiet_hours_repo()
        sentinel = "SOMA_AUDIT_SENTINEL_PROMPT"
        audit_tmp = tempfile.TemporaryDirectory()
        with tmp, audit_tmp, patch.object(gateway.core.graphify, "query", return_value={"graphs": [], "answers": [], "warnings": []}), patch.object(
            soma_audit, "SOMA_AUDIT_DIR", Path(audit_tmp.name) / ".soma" / "audit"
        ), patch.object(
            soma_audit, "SOMA_AUDIT_RUNS_DIR", Path(audit_tmp.name) / ".soma" / "audit" / "runs"
        ), patch.object(
            soma_audit, "SOMA_AUDIT_RAW_DIR", Path(audit_tmp.name) / ".soma" / "audit" / "raw"
        ), patch.object(
            soma_audit, "SOMA_AUDIT_LATEST", Path(audit_tmp.name) / ".soma" / "audit" / "latest.json"
        ), patch.dict(
            os.environ,
            {
                "SOMA_PROJECT_ROOT": str(root),
                "SOMA_AUDIT_RAW_CAPTURE": "0",
            },
        ):
            payload = json.loads(
                asyncio.run(
                    gateway.tool_registry.call_tool(
                        "soma_prepare_context",
                        {
                            "goal": f"Investigate {sentinel} in CooldownPolicy.swift and MissingThing.swift",
                            "budget": "fast",
                            "depth": "deterministic",
                            "run_id": "run_audit_default",
                            "task_id": "audit_default",
                        },
                    )
                )
            )
            latest_text = soma_audit.SOMA_AUDIT_LATEST.read_text(encoding="utf-8")
            latest = json.loads(latest_text)

        self.assertEqual(payload["audit"]["run_id"], "run_audit_default")
        self.assertIn("MissingThing.swift", json.dumps(payload["audit"]["missing_evidence"]))
        self.assertNotIn(sentinel, latest_text)
        self.assertFalse((Path(audit_tmp.name) / ".soma" / "audit" / "raw" / "run_audit_default").exists())
        self.assertEqual(latest["prompt_hash"], payload["audit"]["prompt_hash"])

    def test_audit_slash_concepts_do_not_become_missing_files(self):
        tmp, root = make_quiet_hours_repo()
        with tmp:
            discovered = iter_project_files(str(root))
            repo_index = build_repo_index(str(root), discovered)
            evidence = select_evidence(
                str(root),
                "Investigate compile/runtime and registration/listing in CooldownPolicy",
                "swift",
                repo_index,
                {"packet_mode": "debug", "explicit_paths": [], "changed_paths": [], "error_paths": []},
            )
            quality = assess_evidence_quality("CooldownPolicy", evidence, {})
            missing = soma_audit.build_missing_evidence(
                original_prompt="Investigate compile/runtime and registration/listing for GitHub",
                normalized_prompt="Investigate compile/runtime and registration/listing for GitHub",
                project_root=str(root),
                discovered=discovered,
                repo_index=repo_index,
                evidence_items=evidence,
                preflight={},
                evidence_quality=quality,
            )

        self.assertEqual(missing["missing_files"], [])
        self.assertTrue(any(item["reference"] == "compile/runtime" for item in missing["unresolved_concepts"]))
        self.assertTrue(any(item["reference"] == "GitHub" for item in missing["unresolved_concepts"]))

    def test_audit_raw_capture_opt_in_writes_local_artifacts(self):
        tmp, root = make_quiet_hours_repo()
        audit_tmp = tempfile.TemporaryDirectory()
        sentinel = "SOMA_AUDIT_RAW_SENTINEL"
        with tmp, audit_tmp, patch.object(gateway.core.graphify, "query", return_value={"graphs": [], "answers": [], "warnings": []}), patch.object(
            soma_audit, "SOMA_AUDIT_DIR", Path(audit_tmp.name) / ".soma" / "audit"
        ), patch.object(
            soma_audit, "SOMA_AUDIT_RUNS_DIR", Path(audit_tmp.name) / ".soma" / "audit" / "runs"
        ), patch.object(
            soma_audit, "SOMA_AUDIT_RAW_DIR", Path(audit_tmp.name) / ".soma" / "audit" / "raw"
        ), patch.object(
            soma_audit, "SOMA_AUDIT_LATEST", Path(audit_tmp.name) / ".soma" / "audit" / "latest.json"
        ), patch.dict(
            os.environ,
            {
                "SOMA_PROJECT_ROOT": str(root),
                "SOMA_AUDIT_RAW_CAPTURE": "1",
            },
        ):
            payload = json.loads(
                asyncio.run(
                    gateway.tool_registry.call_tool(
                        "soma_prepare_context",
                        {
                            "goal": f"Investigate {sentinel} in CooldownPolicy.swift",
                            "budget": "fast",
                            "depth": "deterministic",
                            "run_id": "run_audit_raw",
                            "task_id": "audit_raw",
                        },
                    )
                )
            )
            latest = json.loads(soma_audit.SOMA_AUDIT_LATEST.read_text(encoding="utf-8"))
            prompt_path = Path(latest["raw_artifacts"]["prompt"])
            packet_path = Path(latest["raw_artifacts"]["packet"])
            prompt_text = prompt_path.read_text(encoding="utf-8")
            packet_text = packet_path.read_text(encoding="utf-8")

        self.assertTrue(payload["audit"]["raw_capture_enabled"])
        self.assertIn(sentinel, prompt_text)
        self.assertTrue(packet_text.startswith("Goal:"))

    def test_audit_quality_mark_updates_report_without_removing_trace(self):
        audit_tmp = tempfile.TemporaryDirectory()
        with audit_tmp, patch.object(soma_audit, "SOMA_AUDIT_DIR", Path(audit_tmp.name) / ".soma" / "audit"), patch.object(
            soma_audit, "SOMA_AUDIT_RUNS_DIR", Path(audit_tmp.name) / ".soma" / "audit" / "runs"
        ), patch.object(
            soma_audit, "SOMA_AUDIT_RAW_DIR", Path(audit_tmp.name) / ".soma" / "audit" / "raw"
        ), patch.object(
            soma_audit, "SOMA_AUDIT_LATEST", Path(audit_tmp.name) / ".soma" / "audit" / "latest.json"
        ):
            report = soma_audit.write_prepare_audit(
                soma_audit.build_prepare_audit(
                    context={"run_id": "run_mark", "task_id": "task_mark", "workflow": "packet_mode"},
                    status="ok",
                    project_root="/tmp/project",
                    project_type="python",
                    original_prompt="Check app.py",
                    normalized_prompt="Check app.py",
                    packet="Goal:\nCheck app.py",
                    estimated_tokens=10,
                    evidence_items=[{"path": "/tmp/project/app.py", "kind": "source", "reason": "test"}],
                    missing_evidence={"status": "ok", "unresolved_references": []},
                    evidence_quality={"status": "ok", "warnings": []},
                    tool_calls_expected=["Use packet first."],
                    language_optimization={},
                )
            )
            marked = soma_audit.mark_quality("run_mark", "needs_more_evidence", "Need one more file.")

        self.assertEqual(report["selected_evidence"][0]["path"], marked["selected_evidence"][0]["path"])
        self.assertEqual(marked["status"], "degraded")
        self.assertEqual(marked["quality_review"]["status"], "needs_more_evidence")


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

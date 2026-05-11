import asyncio
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Soma"))

from scout_pipeline import TOKEN_BUDGETS
from scout_pipeline_module.discovery import build_repo_index, detect_project_type, iter_project_files
from scout_pipeline_module.gather import build_preflight, select_evidence
from scout_pipeline_module.git import get_git_diff_summary, get_git_status
import token_calculator
from soma_token_savings import build_token_savings
from token_calculator import estimate_payload, estimate_tokens, profile_for
from universal_fixtures import fixture_templates, prepare_fixture_repo

import gateway.core
import gateway.tools.context
import verify_soma_universal_workflow as universal
import soma_token_benchmark


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
                self.assertEqual(payload["token_savings"]["status"], "ok")
                self.assertGreater(payload["token_savings"]["saved_tokens"], 0)
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


if __name__ == "__main__":
    unittest.main()

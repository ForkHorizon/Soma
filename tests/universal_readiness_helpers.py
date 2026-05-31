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

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Soma"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))
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
import rus_to_prompt_stress
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
    _make_quiet_dirs(root)
    _write_quiet_sources(root)
    _write_quiet_docs(root)
    _commit_quiet_repo(root)
    return tmp, root


def _make_quiet_dirs(root):
    for path in ["Moodling/Core", "Moodling/Models", "Moodling/Views", "MoodlingTests", "docs", "fixtures/system_events"]:
        (root / path).mkdir(parents=True, exist_ok=True)


def _write_quiet_sources(root):
    (root / "Package.swift").write_text("// swift-tools-version: 5.9\n", encoding="utf-8")
    (root / "Moodling" / "Core" / "CooldownPolicy.swift").write_text(
        "import Foundation\nstruct CooldownPolicy {\n"
        "func isQuietTime(currentMinute: Int, start: Int, end: Int) -> Bool {\n"
        "if start == end { return true }\n"
        "if start < end { return currentMinute >= start && currentMinute < end }\n"
        "return currentMinute >= start || currentMinute < end\n}\n}\n",
        encoding="utf-8",
    )
    (root / "Moodling" / "Core" / "NudgeScheduler.swift").write_text("struct NudgeScheduler { let cooldownPolicy = CooldownPolicy() }\n", encoding="utf-8")
    (root / "Moodling" / "AppState.swift").write_text("final class AppState { let nudgeScheduler = NudgeScheduler(); func testNudge() {} }\n", encoding="utf-8")
    (root / "Moodling" / "Models" / "MoodlingSettings.swift").write_text("struct MoodlingSettings { var quietHoursEnabled = true; var quietHoursStartMinutes = 23 * 60; var quietHoursEndMinutes = 8 * 60 }\n", encoding="utf-8")
    (root / "Moodling" / "Views" / "SettingsView.swift").write_text("struct SettingsView { let label = \"Quiet hours\" }\n", encoding="utf-8")
    (root / "MoodlingTests" / "CooldownPolicyTests.swift").write_text("import XCTest\nfinal class CooldownPolicyTests: XCTestCase { func testQuietHoursCrossMidnight() {} }\n", encoding="utf-8")


def _write_quiet_docs(root):
    (root / "docs" / "behavior.md").write_text("# Behavior\nQuiet hours suppress nudges and bubbles between start and end, including midnight crossing intervals.\n", encoding="utf-8")
    (root / "fixtures" / "system_events" / "quiet_hours_cross_midnight.jsonl").write_text(
        "{\"type\":\"manual_nudge\",\"expected\":\"allowed_before_quiet_hours\"}\n"
        "{\"type\":\"agent_log\",\"expected\":\"suppressed_after_midnight\"}\n",
        encoding="utf-8",
    )


def _commit_quiet_repo(root):
    subprocess.run(["git", "init"], cwd=root, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
    subprocess.run(["git", "add", "."], cwd=root, check=True)
    subprocess.run(["git", "commit", "-m", "init"], cwd=root, check=True, capture_output=True)


class UniversalReadinessTestCase(unittest.TestCase):
    def setUp(self):
        self.previous_root = os.environ.get("SOMA_PROJECT_ROOT")

    def tearDown(self):
        if self.previous_root is None:
            os.environ.pop("SOMA_PROJECT_ROOT", None)
        else:
            os.environ["SOMA_PROJECT_ROOT"] = self.previous_root


def make_rtp_confidence_case_result():
    case = rus_to_prompt_stress.PromptCase("rtp-test", "unit", "Сделай Project Info компактнее.")
    result = rus_to_prompt_stress.CaseResult(
        id=case.id,
        category=case.category,
        status="ok",
        translation_status="translated",
        improve_status="ok",
        seconds=1.2,
        source_language="ru",
        protected_spans_count=0,
        missing_protected_spans=[],
        placeholder_leak=False,
        internal_instruction_leak=False,
        meta_prompt_output=False,
        improvement_retry_used=False,
        cyrillic_in_translation=0,
        cyrillic_in_improved=0,
        warnings=[],
        translation="Make Project Info more compact.",
        improved_prompt="Make the Project Info section more compact while preserving critical status.",
    )
    return case, result


def rtp_confidence_payload(confidence):
    return {
        "status": "ok",
        "confidence": confidence,
        "verdict": "pass",
        "scores": {
            "intent_preservation": 5,
            "english_quality": 5,
            "protected_span_preservation": 5,
            "actionability": 4,
            "concision": 4,
            "no_invention": 5,
        },
        "warnings": [],
        "notes": ["usable"],
    }

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Scripts"))
sys.path.insert(0, str(ROOT / "Soma"))

import rus_to_prompt_stress  # noqa: E402


def make_result(case: rus_to_prompt_stress.PromptCase, analyzer_model: str) -> rus_to_prompt_stress.CaseResult:
    return rus_to_prompt_stress.CaseResult(
        id=case.id,
        category=case.category,
        status="ok",
        translation_status="translated",
        improve_status="ok",
        seconds=1.0,
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
        translation="Make the project information more compact.",
        improved_prompt=f"Make the project information more compact using {analyzer_model}.",
        translator_model="qwen3.5:9b",
        analyzer_model=analyzer_model,
    )


class RusToPromptConfidenceBatchingTests(unittest.TestCase):
    def test_external_error_classification_catches_rate_limit_and_timeout(self):
        self.assertEqual(
            rus_to_prompt_stress.classify_external_error("429 Resource exhausted: quota exceeded"),
            "rate_limit",
        )
        self.assertEqual(
            rus_to_prompt_stress.classify_external_error("Command timed out after 3600 seconds"),
            "timeout",
        )

    def test_run_health_marks_confidence_failures_as_issues_not_success(self):
        summary = {
            "total": 10,
            "translation_failed": 0,
            "exception": 0,
            "degraded": 0,
            "translation_rejected": 0,
            "confidence_failed_count": 3,
            "protected_span_failures": 0,
            "placeholder_leaks": 0,
            "internal_instruction_leaks": 0,
            "meta_prompt_outputs": 0,
        }

        rus_to_prompt_stress.apply_run_health(summary, 10)

        self.assertEqual(summary["run_status"], "completed_with_issues")
        self.assertFalse(summary["success"])
        self.assertEqual(summary["issue_counts"]["confidence_failed"], 3)

    def test_run_health_marks_incomplete_runs_as_failed(self):
        summary = {
            "total": 7,
            "translation_failed": 0,
            "exception": 0,
            "degraded": 0,
            "translation_rejected": 0,
            "confidence_failed_count": 0,
            "protected_span_failures": 0,
            "placeholder_leaks": 0,
            "internal_instruction_leaks": 0,
            "meta_prompt_outputs": 0,
        }

        rus_to_prompt_stress.apply_run_health(summary, 10)

        self.assertEqual(summary["run_status"], "failed")
        self.assertFalse(summary["success"])
        self.assertEqual(summary["issue_counts"]["incomplete_operations"], 3)

    def test_progress_event_line_is_json_prefixed(self):
        line = rus_to_prompt_stress.progress_event_line(
            event="stage_start",
            stage="translating",
            case_id="rtp-progress",
            category="unit",
            translator_model="qwen3.5:9b",
            analyzer_model=None,
            operation_index=1,
            total_operations=6,
            status="running",
        )

        self.assertTrue(line.startswith(rus_to_prompt_stress.PROGRESS_PREFIX))
        payload = json.loads(line[len(rus_to_prompt_stress.PROGRESS_PREFIX):])
        self.assertEqual(payload["event"], "stage_start")
        self.assertEqual(payload["stage"], "translating")
        self.assertEqual(payload["case_id"], "rtp-progress")
        self.assertEqual(payload["translator_model"], "qwen3.5:9b")
        self.assertEqual(payload["operation_index"], 1)
        self.assertEqual(payload["total_operations"], 6)
        self.assertNotIn("analyzer_model", payload)

    def test_progress_event_line_records_confidence_batch_scope(self):
        line = rus_to_prompt_stress.progress_event_line(
            event="confidence_batch_start",
            stage="overall_confidence_batch",
            case_id="rtp-progress",
            translator_model="translator-a",
            operation_index=3,
            total_operations=12,
            batch_size=5,
            batch_index=1,
            batch_total=2,
            status="running",
        )
        payload = json.loads(line[len(rus_to_prompt_stress.PROGRESS_PREFIX):])

        self.assertEqual(payload["case_id"], "rtp-progress")
        self.assertEqual(payload["translator_model"], "translator-a")
        self.assertEqual(payload["batch_size"], 5)
        self.assertEqual(payload["batch_index"], 1)
        self.assertEqual(payload["batch_total"], 2)

    def test_progress_event_line_records_cooldown_scope(self):
        line = rus_to_prompt_stress.progress_event_line(
            event="cooldown_start",
            stage="cooldown",
            case_id="rtp-progress",
            translator_model="translator-a",
            analyzer_model="improver-a",
            operation_index=3,
            total_operations=12,
            status="running",
            reason="improver stage finished; 30.0s",
        )
        payload = json.loads(line[len(rus_to_prompt_stress.PROGRESS_PREFIX):])

        self.assertEqual(payload["event"], "cooldown_start")
        self.assertEqual(payload["stage"], "cooldown")
        self.assertEqual(payload["case_id"], "rtp-progress")
        self.assertEqual(payload["translator_model"], "translator-a")
        self.assertEqual(payload["analyzer_model"], "improver-a")
        self.assertEqual(payload["reason"], "improver stage finished; 30.0s")

    def test_control_file_helpers_ignore_invalid_and_read_flags(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            control_path = Path(temp_dir) / "control.json"
            self.assertEqual(rus_to_prompt_stress.read_control_file(str(control_path)), {})

            control_path.write_text("{bad json", encoding="utf-8")
            self.assertEqual(rus_to_prompt_stress.read_control_file(str(control_path)), {})

            control_path.write_text(json.dumps({"pause": True, "skip_cooldown": False}), encoding="utf-8")
            self.assertTrue(rus_to_prompt_stress.control_flag(str(control_path), "pause"))
            self.assertFalse(rus_to_prompt_stress.control_flag(str(control_path), "skip_cooldown"))

    def test_translation_confidence_gate_blocks_low_or_failed_translation(self):
        self.assertTrue(
            rus_to_prompt_stress.translation_confidence_allows_improve(
                {"status": "ok", "confidence": 0.82, "verdict": "pass"},
                0.75,
            )
        )
        self.assertFalse(
            rus_to_prompt_stress.translation_confidence_allows_improve(
                {"status": "review", "confidence": 0.62, "verdict": "review"},
                0.75,
            )
        )
        self.assertFalse(
            rus_to_prompt_stress.translation_confidence_allows_improve(
                {"status": "failed", "confidence": None, "verdict": "fail"},
                0.75,
            )
        )

    def test_benchmark_operation_counts_are_separated_by_mode(self):
        self.assertEqual(
            rus_to_prompt_stress.benchmark_operation_count("translation", 100, 19, 8),
            1900,
        )
        self.assertEqual(
            rus_to_prompt_stress.benchmark_operation_count("staged", 100, 19, 8),
            2700,
        )
        self.assertEqual(
            rus_to_prompt_stress.benchmark_operation_count("matrix", 100, 19, 8),
            15200,
        )
        self.assertEqual(
            rus_to_prompt_stress.confidence_logical_check_count("staged", 100, 19, 8),
            3500,
        )
        self.assertEqual(
            rus_to_prompt_stress.confidence_request_estimate("staged", 100, 19, 8, 5),
            2300,
        )

    def test_translation_rejected_result_does_not_have_improved_prompt(self):
        case = rus_to_prompt_stress.PromptCase("rtp-bad-translation", "unit", "Сделай информацию компактнее.")
        result = rus_to_prompt_stress.build_translation_rejected_result(
            case,
            "translator-a",
            "improver-a",
            "local",
            "local",
            {
                "status": "ok",
                "translation_status": "translated",
                "translation": "Make info compact.",
                "source_language": "ru",
                "warnings": [],
            },
            1.5,
            "Translation confidence 0.40 is below threshold 0.75; skipped improver stage.",
        )

        self.assertEqual(result.status, "translation_rejected")
        self.assertIsNone(result.improve_status)
        self.assertEqual(result.improved_prompt, "")
        self.assertEqual(result.improve_seconds, 0.0)
        self.assertIn("skipped improver stage", result.error)

    def test_confidence_batching_stays_inside_one_case_and_translator(self):
        case_one = rus_to_prompt_stress.PromptCase("rtp-one", "unit", "Первый кейс.")
        case_two = rus_to_prompt_stress.PromptCase("rtp-two", "unit", "Второй кейс.")
        first_case_results = [make_result(case_one, f"improver-{index}") for index in range(8)]
        second_case_results = [make_result(case_two, f"improver-{index}") for index in range(3)]

        first_chunks = rus_to_prompt_stress.confidence_chunks_for_group(case_one, first_case_results, "overall", 10)
        second_chunks = rus_to_prompt_stress.confidence_chunks_for_group(case_two, second_case_results, "overall", 10)

        self.assertEqual([len(chunk) for chunk in first_chunks], [8])
        self.assertEqual([len(chunk) for chunk in second_chunks], [3])
        self.assertEqual({item[1].id for chunk in first_chunks for item in chunk}, {"rtp-one"})
        self.assertEqual({item[1].id for chunk in second_chunks for item in chunk}, {"rtp-two"})

        with self.assertRaisesRegex(ValueError, "different cases"):
            rus_to_prompt_stress.confidence_chunks_for_group(
                case_one,
                first_case_results + second_case_results,
                "overall",
                10,
            )

        mixed_translator_results = first_case_results[:]
        mixed_translator_results[-1].translator_model = "another-translator"
        with self.assertRaisesRegex(ValueError, "different translator"):
            rus_to_prompt_stress.confidence_chunks_for_group(
                case_one,
                mixed_translator_results,
                "overall",
                10,
            )

    def test_gemini_batch_confidence_maps_each_item(self):
        case = rus_to_prompt_stress.PromptCase("rtp-batch", "unit", "Сделай информацию компактнее.")
        results = [make_result(case, "improver-a"), make_result(case, "improver-b")]
        items = [(rus_to_prompt_stress.confidence_item_id(result, "overall"), case, result) for result in results]

        def fake_gemini_json(prompt, schema, model, timeout, gemini_bin, temp_prefix):
            payload_start = prompt.index("Payload:")
            payload = json.loads(prompt[payload_start + len("Payload:"):])
            self.assertEqual(len(payload["items"]), 2)
            self.assertEqual({item["case_id"] for item in payload["items"]}, {"rtp-batch"})
            return (
                {
                    "results": [
                        {
                            "id": payload["items"][0]["id"],
                            "status": "ok",
                            "confidence": 0.91,
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
                            "notes": [],
                        },
                        {
                            "id": payload["items"][1]["id"],
                            "status": "review",
                            "confidence": 0.72,
                            "verdict": "review",
                            "scores": {
                                "intent_preservation": 4,
                                "english_quality": 5,
                                "protected_span_preservation": 5,
                                "actionability": 4,
                                "concision": 3,
                                "no_invention": 4,
                            },
                            "warnings": ["Too verbose."],
                            "notes": [],
                        },
                    ]
                },
                {"status": "ok", "seconds": 10.0},
            )

        with patch.object(rus_to_prompt_stress, "run_gemini_json", side_effect=fake_gemini_json):
            by_id = rus_to_prompt_stress.score_confidence_batch_with_provider(
                items,
                provider="gemini",
                model="gemini-3-flash-preview",
                timeout=30,
                stage="overall",
                codex_bin="codex",
                gemini_bin="/opt/homebrew/bin/gemini",
                reasoning_effort="medium",
            )

        self.assertEqual(set(by_id), {item_id for item_id, _case, _result in items})
        self.assertEqual(by_id[items[0][0]]["confidence"], 0.91)
        self.assertEqual(by_id[items[1][0]]["confidence"], 0.72)
        self.assertEqual(by_id[items[0][0]]["batch_size"], 2)
        self.assertEqual(by_id[items[0][0]]["seconds"], 5.0)

    def test_batch_falls_back_when_provider_omits_item(self):
        case = rus_to_prompt_stress.PromptCase("rtp-batch", "unit", "Сделай информацию компактнее.")
        results = [make_result(case, "improver-a"), make_result(case, "improver-b")]
        items = [(rus_to_prompt_stress.confidence_item_id(result, "overall"), case, result) for result in results]
        calls: list[int] = []

        def fake_gemini_json(prompt, schema, model, timeout, gemini_bin, temp_prefix):
            payload = json.loads(prompt[prompt.index("Payload:") + len("Payload:"):])
            if "items" not in payload:
                return (
                    {
                        "status": "ok",
                        "confidence": 0.86,
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
                        "notes": [],
                    },
                    {"status": "ok", "seconds": 4.0},
                )
            calls.append(len(payload["items"]))
            returned_items = payload["items"][:1] if len(payload["items"]) > 1 else payload["items"]
            return (
                {
                    "results": [
                        {
                            "id": item["id"],
                            "status": "ok",
                            "confidence": 0.86,
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
                            "notes": [],
                        }
                        for item in returned_items
                    ]
                },
                {"status": "ok", "seconds": 4.0},
            )

        with patch.object(rus_to_prompt_stress, "run_gemini_json", side_effect=fake_gemini_json):
            by_id = rus_to_prompt_stress.score_confidence_batch_with_provider(
                items,
                provider="gemini",
                model="gemini-3-flash-preview",
                timeout=30,
                stage="overall",
                codex_bin="codex",
                gemini_bin="/opt/homebrew/bin/gemini",
                reasoning_effort="medium",
            )

        self.assertEqual(calls, [2])
        self.assertEqual(set(by_id), {item_id for item_id, _case, _result in items})
        self.assertTrue(all(value["confidence"] == 0.86 for value in by_id.values()))

    def test_hybrid_confidence_uses_two_local_judges_without_gemini_when_clean(self):
        case = rus_to_prompt_stress.PromptCase("rtp-hybrid", "unit", "Сделай информацию компактнее.")
        results = [make_result(case, "improver-a"), make_result(case, "improver-b")]
        items = [(rus_to_prompt_stress.confidence_item_id(result, "overall"), case, result) for result in results]

        def fake_local_json(prompt, schema, model, timeout):
            payload = json.loads(prompt[prompt.index("Payload:") + len("Payload:"):])
            base = 0.92 if model == "local-a" else 0.90
            return (
                {
                    "results": [
                        {
                            "id": item["id"],
                            "status": "ok",
                            "confidence": base,
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
                            "notes": [],
                        }
                        for item in payload["items"]
                    ]
                },
                {"status": "ok", "seconds": 2.0},
            )

        with patch.object(rus_to_prompt_stress, "run_local_ollama_json", side_effect=fake_local_json), \
             patch.object(rus_to_prompt_stress, "run_gemini_json", side_effect=AssertionError("Gemini should not run")):
            by_id = rus_to_prompt_stress.score_confidence_batch_with_provider(
                items,
                provider="hybrid",
                model="gemini-3-flash-preview",
                timeout=30,
                stage="overall",
                codex_bin="codex",
                gemini_bin="/opt/homebrew/bin/gemini",
                reasoning_effort="medium",
                local_models=["local-a", "local-b"],
                hybrid_gemini_model="gemini-3-flash-preview",
            )

        self.assertEqual(set(by_id), {item_id for item_id, _case, _result in items})
        first = by_id[items[0][0]]
        self.assertEqual(first["provider"], "hybrid")
        self.assertFalse(first["hybrid_escalated"])
        self.assertAlmostEqual(first["confidence"], 0.91)
        self.assertEqual(len(first["local_judges"]), 2)

    def test_hybrid_confidence_escalates_problem_items_to_gemini(self):
        case = rus_to_prompt_stress.PromptCase("rtp-hybrid", "unit", "Сделай информацию компактнее.")
        results = [make_result(case, "improver-a"), make_result(case, "improver-b")]
        items = [(rus_to_prompt_stress.confidence_item_id(result, "overall"), case, result) for result in results]

        def fake_local_json(prompt, schema, model, timeout):
            payload = json.loads(prompt[prompt.index("Payload:") + len("Payload:"):])
            confidence = 0.95 if model == "local-a" else 0.52
            return (
                {
                    "results": [
                        {
                            "id": item["id"],
                            "status": "review" if confidence < 0.75 else "ok",
                            "confidence": confidence,
                            "verdict": "review" if confidence < 0.75 else "pass",
                            "scores": {
                                "intent_preservation": 4,
                                "english_quality": 4,
                                "protected_span_preservation": 5,
                                "actionability": 4,
                                "concision": 3,
                                "no_invention": 4,
                            },
                            "warnings": ["uncertain"] if confidence < 0.75 else [],
                            "notes": [],
                        }
                        for item in payload["items"]
                    ]
                },
                {"status": "ok", "seconds": 2.0},
            )

        def fake_gemini_json(prompt, schema, model, timeout, gemini_bin, temp_prefix):
            payload = json.loads(prompt[prompt.index("Payload:") + len("Payload:"):])
            return (
                {
                    "results": [
                        {
                            "id": item["id"],
                            "status": "ok",
                            "confidence": 0.88,
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
                            "notes": [],
                        }
                        for item in payload["items"]
                    ]
                },
                {"status": "ok", "seconds": 5.0},
            )

        with patch.object(rus_to_prompt_stress, "run_local_ollama_json", side_effect=fake_local_json), \
             patch.object(rus_to_prompt_stress, "run_gemini_json", side_effect=fake_gemini_json):
            by_id = rus_to_prompt_stress.score_confidence_batch_with_provider(
                items,
                provider="hybrid",
                model="gemini-3-flash-preview",
                timeout=30,
                stage="overall",
                codex_bin="codex",
                gemini_bin="/opt/homebrew/bin/gemini",
                reasoning_effort="medium",
                local_models=["local-a", "local-b"],
                hybrid_gemini_model="gemini-3-flash-preview",
            )

        first = by_id[items[0][0]]
        self.assertEqual(first["provider"], "hybrid")
        self.assertTrue(first["hybrid_escalated"])
        self.assertEqual(first["fallback_provider"], "gemini")
        self.assertEqual(first["confidence"], 0.88)
        self.assertIn("below threshold", first["hybrid_escalation_reason"])

    def test_hybrid_confidence_keeps_local_fallback_when_gemini_fails(self):
        case = rus_to_prompt_stress.PromptCase("rtp-hybrid-fallback", "unit", "Сделай информацию компактнее.")
        results = [make_result(case, "improver-a"), make_result(case, "improver-b")]
        items = [(rus_to_prompt_stress.confidence_item_id(result, "overall"), case, result) for result in results]

        def fake_local_json(prompt, schema, model, timeout):
            payload = json.loads(prompt[prompt.index("Payload:") + len("Payload:"):])
            confidence = 0.86 if model == "local-a" else 0.72
            return (
                {
                    "results": [
                        {
                            "id": item["id"],
                            "status": "review" if confidence < 0.80 else "ok",
                            "confidence": confidence,
                            "verdict": "review" if confidence < 0.80 else "pass",
                            "scores": {
                                "intent_preservation": 4,
                                "english_quality": 4,
                                "protected_span_preservation": 5,
                                "actionability": 4,
                                "concision": 3,
                                "no_invention": 4,
                            },
                            "warnings": ["uncertain"] if confidence < 0.80 else [],
                            "notes": [],
                        }
                        for item in payload["items"]
                    ]
                },
                {"status": "ok", "seconds": 2.0},
            )

        def fake_gemini_json(prompt, schema, model, timeout, gemini_bin, temp_prefix):
            return None, {"status": "failed", "error": "429 quota exceeded", "error_type": "rate_limit", "seconds": 1.0}

        with patch.object(rus_to_prompt_stress, "run_local_ollama_json", side_effect=fake_local_json), \
             patch.object(rus_to_prompt_stress, "run_gemini_json", side_effect=fake_gemini_json):
            by_id = rus_to_prompt_stress.score_confidence_batch_with_provider(
                items,
                provider="hybrid",
                model="gemini-3-flash-preview",
                timeout=30,
                stage="overall",
                codex_bin="codex",
                gemini_bin="/opt/homebrew/bin/gemini",
                reasoning_effort="medium",
                local_models=["local-a", "local-b"],
                hybrid_gemini_model="gemini-3-flash-preview",
            )

        first = by_id[items[0][0]]
        self.assertEqual(first["provider"], "hybrid")
        self.assertTrue(first["hybrid_escalated"])
        self.assertTrue(first["fallback_failed"])
        self.assertEqual(first["fallback_error_type"], "rate_limit")
        self.assertEqual(first["status"], "review")
        self.assertEqual(first["confidence"], 0.72)
        self.assertIn("Online fallback failed", first["warnings"][0])

    def test_deterministic_confidence_caps_objective_failures(self):
        case = rus_to_prompt_stress.PromptCase("rtp-cap", "unit", "Сделай информацию компактнее.")
        result = make_result(case, "improver-a")
        result.placeholder_leak = True
        result.internal_instruction_leak = True
        result.cyrillic_in_translation = 4
        confidence = {
            "provider": "hybrid",
            "model": "local-a + local-b",
            "stage": "translation",
            "status": "ok",
            "confidence": 0.96,
            "verdict": "pass",
            "warnings": [],
        }

        capped = rus_to_prompt_stress.apply_deterministic_confidence_caps(confidence, result, "translation")

        self.assertEqual(capped["confidence"], 0.50)
        self.assertEqual(capped["status"], "review")
        self.assertEqual(capped["verdict"], "fail")
        self.assertIn("internal instruction leak", capped["deterministic_confidence_cap_reasons"])


if __name__ == "__main__":
    unittest.main()

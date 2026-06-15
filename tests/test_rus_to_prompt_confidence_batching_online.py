import json
import unittest
from pathlib import Path
from unittest.mock import patch

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Soma"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))

import rus_to_prompt_stress  # noqa: E402


SCORES = {
    "intent_preservation": 5,
    "english_quality": 5,
    "protected_span_preservation": 5,
    "actionability": 4,
    "concision": 4,
    "no_invention": 5,
}


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
        translation="Make information more compact.",
        improved_prompt="Make the information more compact while preserving important details.",
        translator_model="translator-a",
        analyzer_model=analyzer_model,
    )


def response_item(item_id: str, confidence: float, status: str = "ok", verdict: str = "pass", warnings=None) -> dict:
    return {"id": item_id, "status": status, "confidence": confidence, "verdict": verdict, "scores": dict(SCORES), "warnings": warnings or [], "notes": []}


def payload_from(prompt: str) -> dict:
    return json.loads(prompt[prompt.index("Payload:") + len("Payload:"):])


def make_items(case_id="rtp-batch"):
    case = rus_to_prompt_stress.PromptCase(case_id, "unit", "Сделай информацию компактнее.")
    results = [make_result(case, "improver-a"), make_result(case, "improver-b")]
    return case, [(rus_to_prompt_stress.confidence_item_id(result, "overall"), case, result) for result in results]


def score_batch(items, provider="gemini", **overrides):
    kwargs = {
        "provider": provider,
        "model": "gemini-3-flash-preview",
        "timeout": 30,
        "stage": "overall",
        "codex_bin": "codex",
        "gemini_bin": "/opt/homebrew/bin/gemini",
        "reasoning_effort": "medium",
    }
    kwargs.update(overrides)
    return rus_to_prompt_stress.score_confidence_batch_with_provider(items, **kwargs)


class RusToPromptOnlineConfidenceBatchingTests(unittest.TestCase):
    def test_confidence_normalization_preserves_raw_and_uses_fixed_score_ceiling(self):
        confidence = rus_to_prompt_stress.normalize_confidence_payload(
            {
                "status": "success",
                "confidence": 0.95,
                "verdict": "pass",
                "scores": {
                    "intent_preservation": 4,
                    "english_quality": 4,
                    "protected_span_preservation": 5,
                    "no_invention": 4,
                },
                "warnings": [],
                "notes": [],
            },
            provider="local",
            model="judge-a",
            stage="translation",
            seconds=1.0,
        )

        self.assertEqual(confidence["raw_confidence"], 0.95)
        self.assertLess(confidence["confidence"], 0.95)
        self.assertGreater(confidence["confidence"], 0.84)
        self.assertEqual(confidence["status"], "ok")
        self.assertTrue(confidence["calibrated_from_scores"])

    def test_confidence_normalization_canonicalizes_nonstandard_failed_status(self):
        confidence = rus_to_prompt_stress.normalize_confidence_payload(
            {"status": "rejected", "confidence": 0.95, "verdict": "pass", "scores": dict(SCORES), "warnings": [], "notes": []},
            provider="local",
            model="judge-a",
            stage="overall",
            seconds=1.0,
        )

        self.assertEqual(confidence["raw_confidence"], 0.95)
        self.assertIsNone(confidence["confidence"])
        self.assertEqual(confidence["effective_score"], 0.0)
        self.assertEqual(confidence["status"], "failed")
        self.assertEqual(confidence["verdict"], "fail")

    def test_gemini_batch_confidence_maps_each_item(self):
        _case, items = make_items()

        def fake_gemini_json(prompt, schema, model, timeout, gemini_bin, temp_prefix):
            payload = payload_from(prompt)
            self.assertEqual(len(payload["items"]), 2)
            self.assertEqual({item["case_id"] for item in payload["items"]}, {"rtp-batch"})
            results = [response_item(payload["items"][0]["id"], 0.91), response_item(payload["items"][1]["id"], 0.72, "review", "review", ["Too verbose."])]
            return {"results": results}, {"status": "ok", "seconds": 10.0}

        with patch.object(rus_to_prompt_stress, "run_gemini_json", side_effect=fake_gemini_json):
            by_id = score_batch(items)

        self.assertEqual(set(by_id), {item_id for item_id, _case, _result in items})
        self.assertEqual(by_id[items[0][0]]["confidence"], 0.91)
        self.assertEqual(by_id[items[1][0]]["confidence"], 0.72)
        self.assertEqual(by_id[items[0][0]]["batch_size"], 2)
        self.assertEqual(by_id[items[0][0]]["seconds"], 5.0)

    def test_deepseek_batch_confidence_maps_each_item(self):
        _case, items = make_items("rtp-deepseek-batch")

        def fake_deepseek_json(prompt, schema, model, timeout, temp_prefix):
            payload = payload_from(prompt)
            self.assertEqual(model, "deepseek-v4-flash")
            self.assertEqual(len(payload["items"]), 2)
            results = [response_item(item["id"], 0.89) for item in payload["items"]]
            return {"results": results}, {"status": "ok", "seconds": 8.0, "stats": {"usage": {"total_tokens": 42}}}

        with patch.object(rus_to_prompt_stress, "run_deepseek_json", side_effect=fake_deepseek_json):
            by_id = score_batch(items, provider="deepseek", model="deepseek-v4-flash")

        self.assertEqual(set(by_id), {item_id for item_id, _case, _result in items})
        self.assertEqual(by_id[items[0][0]]["provider"], "deepseek")
        self.assertEqual(by_id[items[0][0]]["confidence"], 0.89)
        self.assertEqual(by_id[items[0][0]]["stats"]["usage"]["total_tokens"], 42)

    def test_batch_falls_back_when_provider_omits_item(self):
        _case, items = make_items()
        calls: list[int] = []

        def fake_gemini_json(prompt, schema, model, timeout, gemini_bin, temp_prefix):
            payload = payload_from(prompt)
            if "items" not in payload:
                return {"status": "ok", "confidence": 0.86, "verdict": "pass", "scores": SCORES, "warnings": [], "notes": []}, {"status": "ok", "seconds": 4.0}
            calls.append(len(payload["items"]))
            return {"results": [response_item(item["id"], 0.86) for item in payload["items"][:1]]}, {"status": "ok", "seconds": 4.0}

        with patch.object(rus_to_prompt_stress, "run_gemini_json", side_effect=fake_gemini_json):
            by_id = score_batch(items)

        self.assertEqual(calls, [2])
        self.assertEqual(set(by_id), {item_id for item_id, _case, _result in items})
        self.assertTrue(all(value["confidence"] == 0.86 for value in by_id.values()))

    def test_hybrid_confidence_uses_two_local_judges_without_gemini_when_clean(self):
        _case, items = make_items("rtp-hybrid")

        def fake_local_json(prompt, schema, model, timeout):
            base = 0.92 if model == "local-a" else 0.90
            return {"results": [response_item(item["id"], base) for item in payload_from(prompt)["items"]]}, {"status": "ok", "seconds": 2.0}

        with patch.object(rus_to_prompt_stress, "run_local_ollama_json", side_effect=fake_local_json), patch.object(rus_to_prompt_stress, "run_gemini_json", side_effect=AssertionError("Gemini should not run")):
            by_id = score_batch(items, provider="hybrid", local_models=["local-a", "local-b"], hybrid_gemini_model="gemini-3-flash-preview")

        first = by_id[items[0][0]]
        self.assertEqual(set(by_id), {item_id for item_id, _case, _result in items})
        self.assertEqual(first["provider"], "hybrid")
        self.assertFalse(first["hybrid_escalated"])
        self.assertAlmostEqual(first["confidence"], 0.91)
        self.assertEqual(len(first["local_judges"]), 2)

    def test_hybrid_confidence_escalates_problem_items_to_gemini(self):
        _case, items = make_items("rtp-hybrid")

        def fake_local_json(prompt, schema, model, timeout):
            confidence = 0.95 if model == "local-a" else 0.52
            status, verdict = ("review", "review") if confidence < 0.75 else ("ok", "pass")
            return {"results": [response_item(item["id"], confidence, status, verdict, ["uncertain"] if confidence < 0.75 else []) for item in payload_from(prompt)["items"]]}, {"status": "ok", "seconds": 2.0}

        def fake_gemini_json(prompt, schema, model, timeout, gemini_bin, temp_prefix):
            return {"results": [response_item(item["id"], 0.88) for item in payload_from(prompt)["items"]]}, {"status": "ok", "seconds": 5.0}

        with patch.object(rus_to_prompt_stress, "run_local_ollama_json", side_effect=fake_local_json), patch.object(rus_to_prompt_stress, "run_gemini_json", side_effect=fake_gemini_json):
            by_id = score_batch(items, provider="hybrid", local_models=["local-a", "local-b"], hybrid_gemini_model="gemini-3-flash-preview")

        first = by_id[items[0][0]]
        self.assertTrue(first["hybrid_escalated"])
        self.assertEqual(first["fallback_provider"], "gemini")
        self.assertEqual(first["confidence"], 0.88)
        self.assertIn("below threshold", first["hybrid_escalation_reason"])

    def test_hybrid_confidence_escalates_problem_items_to_deepseek(self):
        _case, items = make_items("rtp-hybrid-deepseek")

        def fake_local_json(prompt, schema, model, timeout):
            confidence = 0.93 if model == "local-a" else 0.52
            status, verdict = ("review", "review") if confidence < 0.75 else ("ok", "pass")
            return {"results": [response_item(item["id"], confidence, status, verdict) for item in payload_from(prompt)["items"]]}, {"status": "ok", "seconds": 2.0}

        def fake_deepseek_json(prompt, schema, model, timeout, temp_prefix):
            self.assertEqual(model, "deepseek-v4-flash")
            return {"results": [response_item(item["id"], 0.86) for item in payload_from(prompt)["items"]]}, {"status": "ok", "seconds": 5.0}

        with patch.object(rus_to_prompt_stress, "run_local_ollama_json", side_effect=fake_local_json), patch.object(rus_to_prompt_stress, "run_deepseek_json", side_effect=fake_deepseek_json):
            by_id = score_batch(
                items,
                provider="hybrid",
                local_models=["local-a", "local-b"],
                hybrid_fallback_provider="deepseek",
                hybrid_online_model="deepseek-v4-flash",
            )

        first = by_id[items[0][0]]
        self.assertTrue(first["hybrid_escalated"])
        self.assertEqual(first["fallback_provider"], "deepseek")
        self.assertEqual(first["fallback_model"], "deepseek-v4-flash")
        self.assertEqual(first["confidence"], 0.86)

    def test_hybrid_confidence_keeps_local_fallback_when_gemini_fails(self):
        _case, items = make_items("rtp-hybrid-fallback")

        def fake_local_json(prompt, schema, model, timeout):
            confidence = 0.86 if model == "local-a" else 0.72
            status, verdict = ("review", "review") if confidence < 0.80 else ("ok", "pass")
            return {"results": [response_item(item["id"], confidence, status, verdict, ["uncertain"] if confidence < 0.80 else []) for item in payload_from(prompt)["items"]]}, {"status": "ok", "seconds": 2.0}

        def fake_gemini_json(prompt, schema, model, timeout, gemini_bin, temp_prefix):
            return None, {"status": "failed", "error": "429 quota exceeded", "error_type": "rate_limit", "seconds": 1.0}

        with patch.object(rus_to_prompt_stress, "run_local_ollama_json", side_effect=fake_local_json), patch.object(rus_to_prompt_stress, "run_gemini_json", side_effect=fake_gemini_json):
            by_id = score_batch(items, provider="hybrid", local_models=["local-a", "local-b"], hybrid_gemini_model="gemini-3-flash-preview")

        first = by_id[items[0][0]]
        self.assertTrue(first["hybrid_escalated"])
        self.assertTrue(first["fallback_failed"])
        self.assertEqual(first["fallback_error_type"], "rate_limit")
        self.assertEqual(first["status"], "review")
        self.assertEqual(first["confidence"], 0.72)
        self.assertIn("Online fallback failed", first["warnings"][0])

    def test_deterministic_confidence_caps_objective_failures(self):
        case, _items = make_items("rtp-cap")
        result = make_result(case, "improver-a")
        result.placeholder_leak = True
        result.internal_instruction_leak = True
        result.cyrillic_in_translation = 4
        confidence = {"provider": "hybrid", "model": "local-a + local-b", "stage": "translation", "status": "ok", "confidence": 0.96, "verdict": "pass", "warnings": []}

        capped = rus_to_prompt_stress.apply_deterministic_confidence_caps(confidence, result, "translation")

        self.assertIsNone(capped["confidence"])
        self.assertEqual(capped["raw_confidence"], 0.96)
        self.assertEqual(capped["effective_score"], 0.0)
        self.assertEqual(capped["status"], "failed")
        self.assertEqual(capped["verdict"], "fail")
        self.assertIn("internal instruction leak", capped["deterministic_confidence_cap_reasons"])

    def test_translation_prompt_rewrite_caps_translation_confidence_and_blocks_gate(self):
        case, _items = make_items("rtp-translation-rewrite")
        result = make_result(case, "translation-only")
        result.status = "translation_only"
        result.improve_status = None
        result.improved_prompt = ""
        result.translation = "**Task:** Determine additional AI features for the editor.\n\nRequirements:\n- Prioritize implementation value."
        confidence = {"provider": "hybrid", "model": "local-a + local-b", "stage": "translation", "status": "ok", "confidence": 0.99, "verdict": "pass", "warnings": []}

        capped = rus_to_prompt_stress.apply_deterministic_confidence_caps(confidence, result, "translation")

        self.assertIsNone(capped["confidence"])
        self.assertEqual(capped["raw_confidence"], 0.99)
        self.assertEqual(capped["effective_score"], 0.0)
        self.assertEqual(capped["status"], "failed")
        self.assertEqual(capped["verdict"], "fail")
        self.assertFalse(rus_to_prompt_stress.translation_confidence_allows_improve(capped, 0.50))
        self.assertTrue(any("prompt rewrite" in reason for reason in capped["deterministic_confidence_cap_reasons"]))

    def test_overall_confidence_caps_degraded_warning_fallback_result(self):
        case, _items = make_items("rtp-overall-cap")
        result = make_result(case, "improver-a")
        result.status = "degraded"
        result.improve_status = "degraded"
        result.improved_prompt = result.translation
        result.warnings = [
            "Prompt improvement failed validation: retry failed",
            "Codex improvement failed validation: dropped protected placeholders",
        ]
        confidence = {"provider": "hybrid", "model": "local-a + local-b", "stage": "overall", "status": "ok", "confidence": 1.0, "verdict": "pass", "warnings": []}

        capped = rus_to_prompt_stress.apply_deterministic_confidence_caps(confidence, result, "overall")

        self.assertIsNone(capped["confidence"])
        self.assertEqual(capped["raw_confidence"], 1.0)
        self.assertEqual(capped["effective_score"], 0.0)
        self.assertEqual(capped["status"], "failed")
        self.assertEqual(capped["verdict"], "fail")
        reasons = "\n".join(capped["deterministic_confidence_cap_reasons"])
        self.assertIn("pipeline status degraded", reasons)
        self.assertIn("pipeline warning", reasons)
        self.assertIn("fell back to translation", reasons)

    def test_reasoning_transcript_output_caps_improver_confidence(self):
        case = rus_to_prompt_stress.PromptCase("rtp-reasoning-leak", "unit", "Проверь, что последний линтер для SWIFT работает корректно.")
        result = rus_to_prompt_stress.build_case_result_from_payloads(
            case,
            "qwen3.5:9b",
            "qwen3:30b-a3b",
            "local",
            "local",
            {"status": "ok", "translation_status": "translated", "translation": "Verify that the latest linter for SWIFT works correctly.", "source_language": "ru", "warnings": []},
            {
                "status": "ok",
                "improved_prompt": (
                    "Hmm, the user is asking me to correct a rejected prompt rewrite. "
                    "The key issue was that the previous rewrite leaked internal instructions. "
                    "Verify that the latest linter for SWIFT works correctly."
                ),
                "warnings": [],
            },
            1.0,
            1.0,
        )
        confidence = {"provider": "hybrid", "model": "local-a + local-b", "stage": "improve", "status": "ok", "confidence": 0.95, "verdict": "pass", "warnings": []}

        capped = rus_to_prompt_stress.apply_deterministic_confidence_caps(confidence, result, "improve")

        self.assertTrue(result.internal_instruction_leak)
        self.assertTrue(result.meta_prompt_output)
        self.assertIsNone(capped["confidence"])
        self.assertEqual(capped["raw_confidence"], 0.95)
        self.assertEqual(capped["effective_score"], 0.0)
        self.assertEqual(capped["status"], "failed")
        self.assertEqual(capped["verdict"], "fail")
        self.assertIn("meta prompt or reasoning transcript", capped["deterministic_confidence_cap_reasons"])

    def test_failed_or_empty_translation_confidence_is_hard_capped(self):
        case, _items = make_items("rtp-empty-translation")
        result = make_result(case, "translation-only")
        result.status = "translation_only"
        result.translation_status = "failed_fallback"
        result.translation = ""
        result.warnings = ["timed out"]
        confidence = {"provider": "hybrid", "model": "local-a + local-b", "stage": "translation", "status": "ok", "confidence": 0.92, "verdict": "pass", "warnings": []}

        capped = rus_to_prompt_stress.apply_deterministic_confidence_caps(confidence, result, "translation")

        self.assertIsNone(capped["confidence"])
        self.assertEqual(capped["raw_confidence"], 0.92)
        self.assertEqual(capped["effective_score"], 0.0)
        self.assertEqual(capped["status"], "failed")
        self.assertEqual(capped["verdict"], "fail")
        reasons = "\n".join(capped["deterministic_confidence_cap_reasons"])
        self.assertIn("empty translation", reasons)
        self.assertIn("translation failed", reasons)
        self.assertFalse(rus_to_prompt_stress.translation_confidence_allows_improve(capped, 0.75))

    def test_reasoning_tag_output_degrades_row_and_caps_improver_confidence(self):
        case = rus_to_prompt_stress.PromptCase("rtp-think-tag", "unit", "Сделай Project Info компактнее.")
        result = rus_to_prompt_stress.build_case_result_from_payloads(
            case,
            "qwen3.5:9b",
            "qwen3:30b-a3b",
            "local",
            "local",
            {"status": "ok", "translation_status": "translated", "translation": "Make Project Info more compact.", "source_language": "ru", "warnings": []},
            {
                "status": "ok",
                "improved_prompt": "Make Project Info more compact.\n</think>\n\nMake Project Info more compact.",
                "warnings": [],
            },
            1.0,
            1.0,
        )
        confidence = {"provider": "hybrid", "model": "local-a + local-b", "stage": "improve", "status": "ok", "confidence": 0.95, "verdict": "pass", "warnings": []}

        capped = rus_to_prompt_stress.apply_deterministic_confidence_caps(confidence, result, "improve")

        self.assertEqual(result.status, "degraded")
        self.assertTrue(result.meta_prompt_output)
        self.assertTrue(any("reasoning tags" in warning for warning in result.warnings))
        self.assertIsNone(capped["confidence"])
        self.assertEqual(capped["raw_confidence"], 0.95)
        self.assertEqual(capped["effective_score"], 0.0)
        self.assertEqual(capped["status"], "failed")
        self.assertEqual(capped["verdict"], "fail")


if __name__ == "__main__":
    unittest.main()

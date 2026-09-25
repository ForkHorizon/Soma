"""Rus to Prompt hybrid (local judges + online fallback) confidence tests."""

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Scripts"))
sys.path.insert(0, str(ROOT / "Soma"))
sys.path.insert(0, str(ROOT / "tests"))

import rus_to_prompt_stress  # noqa: E402
import rus_to_prompt_stress_runner_confidence as runner_confidence  # noqa: E402
import rus_to_prompt_stress_runner_modes as runner_modes  # noqa: E402
from rus_to_prompt_staged_helpers import improved_payload, judge_result, staged_args, translation_payload  # noqa: E402


def hybrid_args(temp_dir):
    return staged_args(
        batch_size=1,
        confidence_referee="hybrid",
        local_confidence_models=["judge-a", "judge-b"],
        hybrid_fallback="off",
        out_dir=temp_dir,
    )


class RusToPromptHybridConfidenceTests(unittest.TestCase):
    def test_hybrid_confidence_runs_local_judges_model_major_with_batch_size_one(self):
        case = rus_to_prompt_stress.PromptCase(
            "staged-hybrid-order",
            "unit",
            "Сделай Project Info компактнее.",
        )
        calls = []

        def fake_translate(prompt, model, provider, args):
            return translation_payload(f"translation from {model}"), 1.0

        def fake_improve(translation, model, provider, args):
            return improved_payload(translation, model)

        def fake_model_major_confidence(items, **kwargs):
            calls.append(
                (
                    kwargs["provider"],
                    kwargs["model"],
                    kwargs["stage"],
                    [item[2].translator_model for item in items],
                    [item[2].analyzer_model for item in items],
                )
            )
            by_id = {}
            for item_id, _case, result in items:
                value = 0.92 if result.translator_model == "translator-b" else 0.82
                if kwargs["stage"] != "translation":
                    value = 0.88
                by_id[item_id] = judge_result(kwargs, value)
            return by_id

        with (
            tempfile.TemporaryDirectory() as temp_dir,
            patch.object(runner_modes, "_translate", side_effect=fake_translate),
            patch.object(runner_modes, "_improve", side_effect=fake_improve),
            patch.object(
                runner_confidence, "score_confidence_batch_with_provider", side_effect=fake_model_major_confidence
            ),
        ):
            runner_modes.run_cases(
                [case],
                ["translator-a", "translator-b"],
                ["improver-a", "improver-b"],
                hybrid_args(temp_dir),
                Path(temp_dir) / "results.jsonl",
                total_operations=4,
            )

        local_calls = [call for call in calls if call[0] == "local"]
        self.assertEqual(
            [(model, stage, translators, analyzers) for _provider, model, stage, translators, analyzers in local_calls],
            [
                ("judge-a", "translation", ["translator-a"], ["translation-only"]),
                ("judge-a", "translation", ["translator-b"], ["translation-only"]),
                ("judge-b", "translation", ["translator-a"], ["translation-only"]),
                ("judge-b", "translation", ["translator-b"], ["translation-only"]),
                ("judge-a", "improve", ["translator-b"], ["improver-a"]),
                ("judge-a", "improve", ["translator-b"], ["improver-b"]),
                ("judge-a", "overall", ["translator-b"], ["improver-a"]),
                ("judge-a", "overall", ["translator-b"], ["improver-b"]),
                ("judge-b", "improve", ["translator-b"], ["improver-a"]),
                ("judge-b", "improve", ["translator-b"], ["improver-b"]),
                ("judge-b", "overall", ["translator-b"], ["improver-a"]),
                ("judge-b", "overall", ["translator-b"], ["improver-b"]),
            ],
        )

    def test_hybrid_confidence_resume_skips_completed_local_judge_state(self):
        case = rus_to_prompt_stress.PromptCase(
            "staged-confidence-resume",
            "unit",
            "Сделай Project Info компактнее.",
        )
        payload = translation_payload("translation from translator-b")
        result = rus_to_prompt_stress.build_translation_only_result(
            case, "translator-b", "translation-only", "local", "none", payload, 1.0
        )
        result.benchmark_mode = "staged"
        item_id = rus_to_prompt_stress.confidence_item_id(result, "translation")
        state_key = json.dumps([item_id, "judge-a"], ensure_ascii=False, separators=(",", ":"))
        saved = judge_result({"provider": "local", "model": "judge-a", "stage": "translation"}, 0.92)
        calls = []

        def fake_resume_confidence(items, **kwargs):
            calls.append((kwargs["provider"], kwargs["model"], kwargs["stage"]))
            return {item_id: judge_result(kwargs, 0.90) for item_id, _case, _result in items}

        with tempfile.TemporaryDirectory() as temp_dir:
            state = {"version": 1, "local_judges": {state_key: saved}}
            state_path = Path(temp_dir) / "confidence_state.json"
            state_path.write_text(json.dumps(state, ensure_ascii=False) + "\n", encoding="utf-8")
            with patch.object(
                runner_confidence, "score_confidence_batch_with_provider", side_effect=fake_resume_confidence
            ):
                runner_confidence.score_and_attach_confidence_batch(
                    case, [(1, result)], "translation", hybrid_args(temp_dir), total_operations=1
                )

        self.assertEqual(calls, [("local", "judge-b", "translation")])
        self.assertAlmostEqual(result.translation_confidence["confidence"], 0.91)


if __name__ == "__main__":
    unittest.main()

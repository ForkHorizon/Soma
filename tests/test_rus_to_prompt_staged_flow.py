import json
import sys
import tempfile
import unittest
from dataclasses import asdict
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Scripts"))
sys.path.insert(0, str(ROOT / "Soma"))

import rus_to_prompt_stress  # noqa: E402
import rus_to_prompt_stress_runner_confidence as runner_confidence  # noqa: E402
import rus_to_prompt_stress_runner_modes as runner_modes  # noqa: E402
import rus_to_prompt_stress_runner_resume as runner_resume  # noqa: E402


class RusToPromptStagedFlowTests(unittest.TestCase):
    def test_staged_flow_picks_one_best_translation_before_all_improvers(self):
        case = rus_to_prompt_stress.PromptCase(
            "staged-best",
            "unit",
            "Сделай Project Info компактнее.",
        )
        translate_calls = []
        improve_calls = []

        def fake_translate(prompt, model, provider, args):
            translate_calls.append(model)
            return {
                "status": "ok",
                "translation_status": "translated",
                "translation": f"translation from {model}",
                "source_language": "ru",
                "warnings": [],
            }, 1.0

        def fake_improve(translation, model, provider, args):
            text = translation["translation"]
            improve_calls.append((text, model))
            return {
                "status": "ok",
                "improved_prompt": f"{text} improved by {model}",
                "warnings": [],
            }, 2.0

        with tempfile.TemporaryDirectory() as temp_dir, patch.object(runner_modes, "_translate", side_effect=fake_translate), patch.object(
            runner_modes,
            "_improve",
            side_effect=fake_improve,
        ), patch.object(runner_confidence, "score_confidence_batch_with_provider", side_effect=fake_confidence):
            results_path = Path(temp_dir) / "results.jsonl"
            results = runner_modes.run_cases(
                [case],
                ["translator-a", "translator-b"],
                ["improver-a", "improver-b"],
                staged_args(),
                results_path,
                total_operations=4,
            )
            written = [json.loads(line) for line in results_path.read_text(encoding="utf-8").splitlines()]

        self.assertEqual(translate_calls, ["translator-a", "translator-b"])
        self.assertEqual(
            improve_calls,
            [
                ("translation from translator-b", "improver-a"),
                ("translation from translator-b", "improver-b"),
            ],
        )
        self.assertEqual(len(results), 4)
        self.assertEqual(len(written), 4)
        self.assertEqual([result.analyzer_model for result in results[:2]], ["translation-only", "translation-only"])
        self.assertEqual({result.translator_model for result in results[2:]}, {"translator-b"})
        self.assertEqual([result.analyzer_model for result in results[2:]], ["improver-a", "improver-b"])
        self.assertEqual(results[0].translation_confidence["confidence"], 0.40)
        self.assertEqual(results[1].translation_confidence["confidence"], 0.92)
        self.assertTrue(all(result.translation_confidence["confidence"] == 0.92 for result in results[2:]))

    def test_staged_flow_rejects_prompt_rewrite_translation_before_selection(self):
        case = rus_to_prompt_stress.PromptCase(
            "staged-rewrite",
            "unit",
            "Определи дополнительные AI-функции для редактора.",
        )
        improve_calls = []

        def fake_translate(prompt, model, provider, args):
            translation = "Determine additional AI features for the editor."
            if model == "translator-b":
                translation = "**Task:** Determine additional AI-driven features for the editor.\n\nRequirements:\n- Prioritize implementation value."
            return {
                "status": "ok",
                "translation_status": "translated",
                "translation": translation,
                "source_language": "ru",
                "warnings": [],
            }, 1.0

        def fake_improve(translation, model, provider, args):
            improve_calls.append((translation["translation"], model))
            return {
                "status": "ok",
                "improved_prompt": f"{translation['translation']} improved by {model}",
                "warnings": [],
            }, 2.0

        def fake_high_rewrite_confidence(items, **kwargs):
            stage = kwargs["stage"]
            by_id = {}
            for item_id, _case, result in items:
                value = 0.82
                if stage == "translation" and result.translator_model == "translator-b":
                    value = 0.99
                elif stage != "translation":
                    value = 0.88
                by_id[item_id] = {
                    "provider": kwargs["provider"],
                    "model": kwargs["model"],
                    "stage": stage,
                    "status": "ok",
                    "confidence": value,
                    "verdict": "pass",
                    "warnings": [],
                }
            return by_id

        with tempfile.TemporaryDirectory() as temp_dir, patch.object(runner_modes, "_translate", side_effect=fake_translate), patch.object(
            runner_modes,
            "_improve",
            side_effect=fake_improve,
        ), patch.object(runner_confidence, "score_confidence_batch_with_provider", side_effect=fake_high_rewrite_confidence):
            results_path = Path(temp_dir) / "results.jsonl"
            results = runner_modes.run_cases(
                [case],
                ["translator-a", "translator-b"],
                ["improver-a"],
                staged_args(),
                results_path,
                total_operations=3,
            )
            written = [json.loads(line) for line in results_path.read_text(encoding="utf-8").splitlines()]

        self.assertEqual(improve_calls, [("Determine additional AI features for the editor.", "improver-a")])
        self.assertEqual({result.translator_model for result in results if result.analyzer_model == "improver-a"}, {"translator-a"})
        rewrite_row = next(row for row in written if row["translator_model"] == "translator-b" and row["analyzer_model"] == "translation-only")
        self.assertIsNone(rewrite_row["translation_confidence"]["confidence"])
        self.assertEqual(rewrite_row["translation_confidence"]["raw_confidence"], 0.99)
        self.assertEqual(rewrite_row["translation_confidence"]["effective_score"], 0.0)
        self.assertEqual(rewrite_row["translation_confidence"]["status"], "failed")
        self.assertEqual(rewrite_row["translation_confidence"]["verdict"], "fail")
        self.assertTrue(any("prompt rewrite" in reason for reason in rewrite_row["translation_confidence"]["deterministic_confidence_cap_reasons"]))

    def test_best_translation_tiebreak_prefers_cleaner_shorter_translation(self):
        case = rus_to_prompt_stress.PromptCase("staged-tiebreak", "unit", "Сделай блок компактнее.")
        verbose_payload = {
            "status": "ok",
            "translation_status": "translated",
            "translation": "I want you to make the block more compact while generally preserving all important information and not changing anything else in the interface.",
            "source_language": "ru",
            "warnings": ["minor style issue"],
        }
        clean_payload = {
            "status": "ok",
            "translation_status": "translated",
            "translation": "Make the block more compact while preserving the important information.",
            "source_language": "ru",
            "warnings": [],
        }
        verbose = rus_to_prompt_stress.build_translation_only_result(case, "translator-a", "translation-only", "local", "none", verbose_payload, 1.0)
        clean = rus_to_prompt_stress.build_translation_only_result(case, "translator-b", "translation-only", "local", "none", clean_payload, 2.0)
        for result in [verbose, clean]:
            result.benchmark_mode = "staged"
            result.translation_confidence = {"status": "ok", "confidence": 0.935, "verdict": "pass", "warnings": []}

        best_payload, _seconds, best_result = runner_confidence.best_translation(
            [(verbose_payload, 1.0, verbose), (clean_payload, 2.0, clean)],
            staged_args(),
        )

        self.assertEqual(best_result.translator_model, "translator-b")
        self.assertEqual(best_payload["translation"], clean_payload["translation"])

    def test_local_judge_statuses_are_normalized_but_raw_status_is_kept(self):
        normalized = runner_confidence.normalize_local_judge_confidence(
            {"provider": "local", "model": "judge-a", "stage": "translation", "status": "translation_only", "confidence": 0.92, "verdict": "pass"}
        )
        self.assertEqual(normalized["status"], "ok")
        self.assertEqual(normalized["raw_status"], "translation_only")

        review = runner_confidence.normalize_local_judge_confidence(
            {"provider": "local", "model": "judge-a", "stage": "translation", "status": "completed", "confidence": 0.60, "verdict": "pass"}
        )
        self.assertEqual(review["status"], "review")

        failed = runner_confidence.normalize_local_judge_confidence(
            {"provider": "local", "model": "judge-a", "stage": "translation", "status": "approved", "confidence": 0.95, "verdict": "fail"}
        )
        self.assertEqual(failed["status"], "failed")

    def test_staged_confidence_runs_after_each_stage_in_batches(self):
        case = rus_to_prompt_stress.PromptCase(
            "staged-batches",
            "unit",
            "Сделай Project Info компактнее.",
        )
        events = []

        def fake_translate(prompt, model, provider, args):
            events.append(("translate", model))
            return {
                "status": "ok",
                "translation_status": "translated",
                "translation": f"translation from {model}",
                "source_language": "ru",
                "warnings": [],
            }, 1.0

        def fake_improve(translation, model, provider, args):
            events.append(("improve", translation["translation"], model))
            return {
                "status": "ok",
                "improved_prompt": f"{translation['translation']} improved by {model}",
                "warnings": [],
            }, 2.0

        def fake_batch_confidence(items, **kwargs):
            events.append((
                "confidence",
                kwargs["stage"],
                [item[2].translator_model for item in items],
                [item[2].analyzer_model for item in items],
            ))
            return fake_confidence(items, **kwargs)

        with tempfile.TemporaryDirectory() as temp_dir, patch.object(runner_modes, "_translate", side_effect=fake_translate), patch.object(
            runner_modes,
            "_improve",
            side_effect=fake_improve,
        ), patch.object(runner_confidence, "score_confidence_batch_with_provider", side_effect=fake_batch_confidence):
            runner_modes.run_cases(
                [case],
                ["translator-a", "translator-b"],
                ["improver-a", "improver-b"],
                staged_args(batch_size=1),
                Path(temp_dir) / "results.jsonl",
                total_operations=4,
            )

        self.assertEqual(
            events,
            [
                ("translate", "translator-a"),
                ("translate", "translator-b"),
                ("confidence", "translation", ["translator-a"], ["translation-only"]),
                ("confidence", "translation", ["translator-b"], ["translation-only"]),
                ("improve", "translation from translator-b", "improver-a"),
                ("improve", "translation from translator-b", "improver-b"),
                ("confidence", "improve", ["translator-b"], ["improver-a"]),
                ("confidence", "improve", ["translator-b"], ["improver-b"]),
                ("confidence", "overall", ["translator-b"], ["improver-a"]),
                ("confidence", "overall", ["translator-b"], ["improver-b"]),
            ],
        )

    def test_hybrid_confidence_runs_local_judges_model_major_with_batch_size_one(self):
        case = rus_to_prompt_stress.PromptCase(
            "staged-hybrid-order",
            "unit",
            "Сделай Project Info компактнее.",
        )
        calls = []

        def fake_translate(prompt, model, provider, args):
            return {
                "status": "ok",
                "translation_status": "translated",
                "translation": f"translation from {model}",
                "source_language": "ru",
                "warnings": [],
            }, 1.0

        def fake_improve(translation, model, provider, args):
            return {
                "status": "ok",
                "improved_prompt": f"{translation['translation']} improved by {model}",
                "warnings": [],
            }, 2.0

        with tempfile.TemporaryDirectory() as temp_dir:
            results_path = Path(temp_dir) / "results.jsonl"

            def fake_model_major_confidence(items, **kwargs):
                calls.append((kwargs["provider"], kwargs["model"], kwargs["stage"], [item[2].translator_model for item in items], [item[2].analyzer_model for item in items]))
                by_id = {}
                for item_id, _case, result in items:
                    value = 0.92 if result.translator_model == "translator-b" else 0.82
                    if kwargs["stage"] != "translation":
                        value = 0.88
                    by_id[item_id] = {
                        "provider": kwargs["provider"],
                        "model": kwargs["model"],
                        "stage": kwargs["stage"],
                        "status": "ok",
                        "confidence": value,
                        "verdict": "pass",
                        "warnings": [],
                    }
                return by_id

            with patch.object(runner_modes, "_translate", side_effect=fake_translate), patch.object(
                runner_modes,
                "_improve",
                side_effect=fake_improve,
            ), patch.object(runner_confidence, "score_confidence_batch_with_provider", side_effect=fake_model_major_confidence):
                runner_modes.run_cases(
                    [case],
                    ["translator-a", "translator-b"],
                    ["improver-a", "improver-b"],
                    staged_args(batch_size=1, confidence_referee="hybrid", local_confidence_models=["judge-a", "judge-b"], hybrid_fallback="off", out_dir=temp_dir),
                    results_path,
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

    def test_staged_translation_checkpoint_is_written_before_confidence_finishes(self):
        case = rus_to_prompt_stress.PromptCase(
            "staged-checkpoint",
            "unit",
            "Сделай Project Info компактнее.",
        )
        observed_checkpoint = []

        def fake_translate(prompt, model, provider, args):
            return {
                "status": "ok",
                "translation_status": "translated",
                "translation": f"translation from {model}",
                "source_language": "ru",
                "warnings": [],
            }, 1.0

        def fake_improve(translation, model, provider, args):
            return {
                "status": "ok",
                "improved_prompt": f"{translation['translation']} improved by {model}",
                "warnings": [],
            }, 2.0

        with tempfile.TemporaryDirectory() as temp_dir:
            results_path = Path(temp_dir) / "results.jsonl"

            def fake_checkpoint_confidence(items, **kwargs):
                if kwargs["stage"] == "translation":
                    rows = [json.loads(line) for line in results_path.read_text(encoding="utf-8").splitlines()]
                    observed_checkpoint.append(rows)
                    self.assertEqual(len(rows), 1)
                    self.assertEqual(rows[0]["analyzer_model"], "translation-only")
                    self.assertIsNone(rows[0].get("translation_confidence"))
                return fake_confidence(items, **kwargs)

            with patch.object(runner_modes, "_translate", side_effect=fake_translate), patch.object(
                runner_modes,
                "_improve",
                side_effect=fake_improve,
            ), patch.object(runner_confidence, "score_confidence_batch_with_provider", side_effect=fake_checkpoint_confidence):
                runner_modes.run_cases(
                    [case],
                    ["translator-b"],
                    ["improver-a"],
                    staged_args(),
                    results_path,
                    total_operations=2,
                )

            final_rows = [json.loads(line) for line in results_path.read_text(encoding="utf-8").splitlines()]

        self.assertTrue(observed_checkpoint)
        self.assertEqual(len(final_rows), 2)
        self.assertIsNotNone(final_rows[0].get("translation_confidence"))
        self.assertEqual(final_rows[0]["analyzer_model"], "translation-only")

    def test_staged_resume_reuses_saved_rows_without_duplicates(self):
        case = rus_to_prompt_stress.PromptCase(
            "staged-resume",
            "unit",
            "Сделай Project Info компактнее.",
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            results_path = Path(temp_dir) / "results.jsonl"
            first_translate_calls: list[str] = []
            first_improve_calls: list[tuple[str, str]] = []
            self._run_staged_case(
                case,
                results_path,
                ["translator-a", "translator-b"],
                ["improver-a"],
                first_translate_calls,
                first_improve_calls,
                total_operations=3,
            )
            self.assertEqual(first_translate_calls, ["translator-a", "translator-b"])
            self.assertEqual(first_improve_calls, [("translation from translator-b", "improver-a")])

            second_translate_calls: list[str] = []
            second_improve_calls: list[tuple[str, str]] = []
            first_load = runner_resume.load_resume_results(results_path, "staged")
            second_load = runner_resume.load_resume_results(results_path, "staged")
            self.assertEqual(first_load, second_load)
            resumed = self._run_staged_case(
                case,
                results_path,
                ["translator-a", "translator-b"],
                ["improver-a", "improver-b"],
                second_translate_calls,
                second_improve_calls,
                total_operations=4,
                existing_results=first_load,
            )
            self.assertEqual(second_translate_calls, [])
            self.assertEqual(second_improve_calls, [("translation from translator-b", "improver-b")])
            self.assertEqual(len(resumed), 4)

            third_translate_calls: list[str] = []
            third_improve_calls: list[tuple[str, str]] = []
            third_load = runner_resume.load_resume_results(results_path, "staged")
            final = self._run_staged_case(
                case,
                results_path,
                ["translator-a", "translator-b"],
                ["improver-a", "improver-b"],
                third_translate_calls,
                third_improve_calls,
                total_operations=4,
                existing_results=third_load,
            )
            written = [json.loads(line) for line in results_path.read_text(encoding="utf-8").splitlines()]

        self.assertEqual(third_translate_calls, [])
        self.assertEqual(third_improve_calls, [])
        self.assertEqual(len(final), 4)
        self.assertEqual(len(written), 4)
        self.assertEqual(len({(row["id"], row["translator_model"], row["analyzer_model"]) for row in written}), 4)

    def test_staged_resume_scores_checkpoint_translation_before_selection(self):
        case = rus_to_prompt_stress.PromptCase(
            "staged-resume-checkpoint",
            "unit",
            "Сделай Project Info компактнее.",
        )
        payload = {
            "status": "ok",
            "translation_status": "translated",
            "translation": "translation from translator-b",
            "source_language": "ru",
            "warnings": [],
        }
        checkpoint = rus_to_prompt_stress.build_translation_only_result(
            case,
            "translator-b",
            "translation-only",
            "local",
            "none",
            payload,
            1.0,
        )
        checkpoint.benchmark_mode = "staged"
        improve_calls = []

        def fake_translate(prompt, model, provider, args):
            raise AssertionError("resume should reuse checkpoint translation")

        def fake_improve(translation, model, provider, args):
            improve_calls.append((translation["translation"], model))
            return {
                "status": "ok",
                "improved_prompt": f"{translation['translation']} improved by {model}",
                "warnings": [],
            }, 2.0

        with tempfile.TemporaryDirectory() as temp_dir:
            results_path = Path(temp_dir) / "results.jsonl"
            results_path.write_text(json.dumps(asdict(checkpoint), ensure_ascii=False) + "\n", encoding="utf-8")
            existing = runner_resume.load_resume_results(results_path, "staged")
            with patch.object(runner_modes, "_translate", side_effect=fake_translate), patch.object(
                runner_modes,
                "_improve",
                side_effect=fake_improve,
            ), patch.object(runner_confidence, "score_confidence_batch_with_provider", side_effect=fake_confidence):
                results = runner_modes.run_cases(
                    [case],
                    ["translator-b"],
                    ["improver-a"],
                    staged_args(),
                    results_path,
                    total_operations=2,
                    existing_results=existing,
                )
            written = [json.loads(line) for line in results_path.read_text(encoding="utf-8").splitlines()]

        self.assertEqual(improve_calls, [("translation from translator-b", "improver-a")])
        self.assertEqual(len(results), 2)
        self.assertEqual(len(written), 2)
        translation_rows = [row for row in written if row["analyzer_model"] == "translation-only"]
        self.assertEqual(len(translation_rows), 1)
        self.assertIsNotNone(translation_rows[0].get("translation_confidence"))

    def test_hybrid_confidence_resume_skips_completed_local_judge_state(self):
        case = rus_to_prompt_stress.PromptCase(
            "staged-confidence-resume",
            "unit",
            "Сделай Project Info компактнее.",
        )
        payload = {
            "status": "ok",
            "translation_status": "translated",
            "translation": "translation from translator-b",
            "source_language": "ru",
            "warnings": [],
        }
        result = rus_to_prompt_stress.build_translation_only_result(
            case,
            "translator-b",
            "translation-only",
            "local",
            "none",
            payload,
            1.0,
        )
        result.benchmark_mode = "staged"
        item_id = rus_to_prompt_stress.confidence_item_id(result, "translation")
        calls = []

        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = Path(temp_dir) / "confidence_state.json"
            state_path.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "local_judges": {
                            json.dumps([item_id, "judge-a"], ensure_ascii=False, separators=(",", ":")): {
                                "provider": "local",
                                "model": "judge-a",
                                "stage": "translation",
                                "status": "ok",
                                "confidence": 0.92,
                                "verdict": "pass",
                                "warnings": [],
                            }
                        },
                    },
                    ensure_ascii=False,
                )
                + "\n",
                encoding="utf-8",
            )

            def fake_resume_confidence(items, **kwargs):
                calls.append((kwargs["provider"], kwargs["model"], kwargs["stage"]))
                return {
                    item_id: {
                        "provider": kwargs["provider"],
                        "model": kwargs["model"],
                        "stage": kwargs["stage"],
                        "status": "ok",
                        "confidence": 0.90,
                        "verdict": "pass",
                        "warnings": [],
                    }
                    for item_id, _case, _result in items
                }

            with patch.object(runner_confidence, "score_confidence_batch_with_provider", side_effect=fake_resume_confidence):
                runner_confidence.score_and_attach_confidence_batch(
                    case,
                    [(1, result)],
                    "translation",
                    staged_args(batch_size=1, confidence_referee="hybrid", local_confidence_models=["judge-a", "judge-b"], hybrid_fallback="off", out_dir=temp_dir),
                    total_operations=1,
                )

        self.assertEqual(calls, [("local", "judge-b", "translation")])
        self.assertAlmostEqual(result.translation_confidence["confidence"], 0.91)

    def _run_staged_case(
        self,
        case,
        results_path,
        translators,
        improvers,
        translate_calls,
        improve_calls,
        total_operations,
        existing_results=None,
    ):
        def fake_translate(prompt, model, provider, args):
            translate_calls.append(model)
            return {
                "status": "ok",
                "translation_status": "translated",
                "translation": f"translation from {model}",
                "source_language": "ru",
                "warnings": [],
            }, 1.0

        def fake_improve(translation, model, provider, args):
            text = translation["translation"]
            improve_calls.append((text, model))
            return {
                "status": "ok",
                "improved_prompt": f"{text} improved by {model}",
                "warnings": [],
            }, 2.0

        with patch.object(runner_modes, "_translate", side_effect=fake_translate), patch.object(
            runner_modes,
            "_improve",
            side_effect=fake_improve,
        ), patch.object(runner_confidence, "score_confidence_batch_with_provider", side_effect=fake_confidence):
            return runner_modes.run_cases(
                [case],
                translators,
                improvers,
                staged_args(),
                results_path,
                total_operations=total_operations,
                existing_results=existing_results,
            )


def staged_args(batch_size=10, confidence_referee="local", local_confidence_models=None, hybrid_fallback="gemini", out_dir="."):
    return SimpleNamespace(
        benchmark_mode="staged",
        translator_provider="local",
        analyzer_provider="local",
        confidence_referee=confidence_referee,
        confidence_model="judge-model",
        confidence_reasoning_effort="medium",
        confidence_batch_size=batch_size,
        local_confidence_models=local_confidence_models or ["judge-model"],
        hybrid_confidence_gemini_model="gemini-judge",
        hybrid_confidence_fallback_referee=hybrid_fallback,
        hybrid_confidence_local_threshold=0.80,
        hybrid_confidence_disagreement_threshold=0.15,
        translation_confidence_threshold=0.75,
        codex_bin="codex",
        gemini_bin="gemini",
        codex_stage_timeout=30,
        gemini_stage_timeout=30,
        model_profile="gpt-5.5",
        stage_cooldown_seconds=0,
        control_file=None,
        out_dir=out_dir,
    )


def fake_confidence(items, **kwargs):
    by_id = {}
    stage = kwargs["stage"]
    for item_id, _case, result in items:
        value = confidence_value_for(result, stage)
        by_id[item_id] = {
            "provider": kwargs["provider"],
            "model": kwargs["model"],
            "stage": stage,
            "status": "ok",
            "confidence": value,
            "verdict": "pass",
            "warnings": [],
        }
    return by_id


def confidence_value_for(result, stage):
    if stage == "translation":
        return {
            "translator-a": 0.40,
            "translator-b": 0.92,
        }[result.translator_model]
    return 0.88


if __name__ == "__main__":
    unittest.main()

import json
import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))

import rus_to_prompt_stats


def write_run(root: Path, name: str, rows: list[dict], *, finished_at: str = "2026-05-29T10:00:00+00:00") -> Path:
    run = root / name
    run.mkdir(parents=True)
    summary = {
        "finished_at": finished_at,
        "translator_providers": {
            "gemini-3-flash-preview": "gemini",
            "qwen3.5:9b": "local",
        },
        "analyzer_providers": {
            "gpt-5.5": "codex",
            "gemma4:e4b": "local",
        },
    }
    (run / "summary.json").write_text(json.dumps(summary), encoding="utf-8")
    (run / "results.jsonl").write_text(
        "\n".join(json.dumps(row) for row in rows) + "\n",
        encoding="utf-8",
    )
    return run


class RusToPromptStatsTests(unittest.TestCase):
    def test_translation_attempts_are_deduped_across_improvers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rows = [
                {
                    "id": "case-001",
                    "category": "matrix",
                    "status": "ok",
                    "translation_status": "translated",
                    "improve_status": "ok",
                    "translator_model": "gemini-3-flash-preview",
                    "analyzer_model": "gpt-5.5",
                    "translation": "Make the project info compact.",
                    "translation_confidence": {"status": "ok", "confidence": 0.9},
                    "improve_confidence": {"status": "ok", "confidence": 0.95},
                    "translation_seconds": 3.0,
                    "improve_seconds": 4.0,
                    "warnings": [],
                },
                {
                    "id": "case-001",
                    "category": "matrix",
                    "status": "ok",
                    "translation_status": "translated",
                    "improve_status": "ok",
                    "translator_model": "gemini-3-flash-preview",
                    "analyzer_model": "gemma4:e4b",
                    "translation": "Make the project info compact.",
                    "translation_confidence": {"status": "ok", "confidence": 0.7},
                    "improve_confidence": {"status": "review", "confidence": 0.65},
                    "translation_seconds": 3.0,
                    "improve_seconds": 2.0,
                    "warnings": ["weak polish"],
                },
            ]
            write_run(root, "matrix", rows)

            payload = rus_to_prompt_stats.aggregate_stats(root)
            translation = payload["translation_models"][0]
            improvers = {row["model"]: row for row in payload["improver_models"]}

            self.assertEqual(translation["model"], "gemini-3-flash-preview")
            self.assertEqual(translation["provider"], "Gemini")
            self.assertEqual(translation["attempts"], 1)
            self.assertEqual(translation["confidence_count"], 1)
            self.assertAlmostEqual(translation["avg_confidence"], 0.8)
            self.assertEqual(improvers["gpt-5.5"]["attempts"], 1)
            self.assertEqual(improvers["gemma4:e4b"]["attempts"], 1)
            self.assertEqual(improvers["gemma4:e4b"]["low_confidence_count"], 1)

    def test_model_attempts_include_historical_runs_and_queue_attempts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            historical_rows = [
                {
                    "id": f"case-{index:03d}",
                    "category": "translation",
                    "status": "translation_only",
                    "translation_status": "translated",
                    "benchmark_mode": "translation",
                    "translator_model": "qwen3.5:9b",
                    "analyzer_model": "translation-only",
                    "translation": f"Translation {index}",
                    "translation_confidence": {"status": "ok", "confidence": 0.90},
                    "translation_seconds": 1.0,
                    "warnings": [],
                }
                for index in range(40)
            ]
            queue_rows = [
                {
                    "id": "rpq-one",
                    "category": "custom",
                    "status": "translation_only",
                    "translation_status": "translated",
                    "benchmark_mode": "staged",
                    "translator_model": "qwen3.5:9b",
                    "analyzer_model": "translation-only",
                    "translation": "One queue translation",
                    "translation_confidence": {"status": "ok", "confidence": 0.94},
                    "translation_seconds": 1.5,
                    "warnings": [],
                }
            ]
            write_run(root, "historical-translation", historical_rows, finished_at="2026-05-30T10:00:00+00:00")
            write_run(root, "queue-one", queue_rows, finished_at="2026-05-31T10:00:00+00:00")

            payload = rus_to_prompt_stats.aggregate_stats(root)
            translation = payload["translation_models"][0]

            self.assertEqual(payload["scanned_runs"], 2)
            self.assertEqual(translation["model"], "qwen3.5:9b")
            self.assertEqual(translation["attempts"], 41)
            self.assertEqual([run["attempts"] for run in translation["recent_runs"]], [1, 40])

    def test_skips_invalid_and_incomplete_runs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "dry").mkdir()
            (root / "dry" / "summary.json").write_text("{}", encoding="utf-8")
            (root / "bad").mkdir()
            (root / "bad" / "summary.json").write_text("{bad json", encoding="utf-8")
            (root / "bad" / "results.jsonl").write_text("{}", encoding="utf-8")
            write_run(
                root,
                "good",
                [
                    {
                        "id": "case-001",
                        "status": "translation_failed",
                        "translation_status": "failed",
                        "translator_model": "qwen3.5:9b",
                        "analyzer_model": "gpt-5.5",
                        "translation": "",
                        "translation_confidence": {"status": "failed"},
                        "warnings": ["offline"],
                    }
                ],
            )

            payload = rus_to_prompt_stats.aggregate_stats(root)
            self.assertEqual(payload["scanned_runs"], 1)
            self.assertEqual(payload["skipped_runs"], 2)
            self.assertEqual(payload["translation_models"][0]["pipeline_failed_count"], 1)
            self.assertEqual(payload["translation_models"][0]["confidence_failed_count"], 1)
            self.assertEqual(payload["translation_models"][0]["problem_count"], 1)
            self.assertEqual(payload["translation_models"][0]["worst_effective_score"], 0.0)
            self.assertEqual(payload["improver_models"], [])

    def test_old_hard_cap_review_rows_do_not_raise_translation_average(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_run(
                root,
                "old-hard-cap",
                [
                    {
                        "id": "case-old-cap",
                        "category": "translation",
                        "status": "translation_only",
                        "translation_status": "translated",
                        "translator_model": "gemma3n:e4b",
                        "analyzer_model": "translation-only",
                        "translation": "Preserve __SOMA_PROTECTED_SPAN_0__.",
                        "translation_confidence": {
                            "status": "review",
                            "confidence": 0.50,
                            "verdict": "fail",
                            "deterministic_confidence_cap_reasons": ["internal placeholder leak"],
                        },
                        "translation_seconds": 1.0,
                        "warnings": [],
                    }
                ],
            )

            payload = rus_to_prompt_stats.aggregate_stats(root)
            translation = payload["translation_models"][0]

            self.assertEqual(translation["model"], "gemma3n:e4b")
            self.assertIsNone(translation["avg_confidence"])
            self.assertEqual(translation["quality_score"], 0.0)
            self.assertEqual(translation["confidence_count"], 0)
            self.assertEqual(translation["confidence_failed_count"], 1)
            self.assertEqual(translation["problem_count"], 1)
            self.assertEqual(translation["worst_effective_score"], 0.0)
            self.assertEqual(translation["worst_cases"][0]["effective_score"], 0.0)

    def test_provider_detection_covers_local_codex_and_gemini(self):
        self.assertEqual(rus_to_prompt_stats.provider_for_model("qwen3.5:9b"), "Local")
        self.assertEqual(rus_to_prompt_stats.provider_for_model("gpt-5.5"), "Codex")
        self.assertEqual(rus_to_prompt_stats.provider_for_model("gpt-5.3-codex"), "Codex")
        self.assertEqual(rus_to_prompt_stats.provider_for_model("codex-auto-review"), "Codex")
        self.assertEqual(rus_to_prompt_stats.provider_for_model("gemini-3-flash-preview"), "Gemini")
        self.assertEqual(rus_to_prompt_stats.provider_for_model("", ""), "Unknown")

    def test_translation_only_rows_do_not_count_as_improver_attempts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_run(
                root,
                "translation-only",
                [
                    {
                        "id": "case-001",
                        "category": "translation",
                        "status": "ok",
                        "translation_status": "translated",
                        "improve_status": None,
                        "benchmark_mode": "translation",
                        "translator_model": "qwen3.5:9b",
                        "analyzer_model": "translation-only",
                        "translation": "Make the project info compact.",
                        "improved_prompt": "",
                        "translation_confidence": {"status": "ok", "confidence": 0.92},
                        "translation_seconds": 3.0,
                        "warnings": [],
                    }
                ],
            )

            payload = rus_to_prompt_stats.aggregate_stats(root)

            self.assertEqual(payload["translation_models"][0]["model"], "qwen3.5:9b")
            self.assertEqual(payload["translation_models"][0]["attempts"], 1)
            self.assertEqual(payload["improver_models"], [])

    def test_improver_stats_cap_reasoning_transcripts_from_saved_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_run(
                root,
                "queue-reasoning-leak",
                [
                    {
                        "id": "case-001",
                        "category": "custom",
                        "status": "ok",
                        "translation_status": "translated",
                        "improve_status": "ok",
                        "translator_model": "qwen3.5:9b",
                        "analyzer_model": "qwen3:30b-a3b",
                        "translation": "Verify that the latest linter for SWIFT works correctly.",
                        "improved_prompt": (
                            "Hmm, the user is asking me to correct a rejected prompt rewrite. "
                            "The key issue was that the previous rewrite leaked internal instructions. "
                            "Verify that the latest linter for SWIFT works correctly."
                        ),
                        "translation_confidence": {"status": "ok", "confidence": 0.95},
                        "improve_confidence": {"status": "ok", "confidence": 0.875},
                        "translation_seconds": 3.0,
                        "improve_seconds": 10.0,
                        "warnings": [],
                    }
                ],
            )

            payload = rus_to_prompt_stats.aggregate_stats(root)
            improver = payload["improver_models"][0]

            self.assertEqual(improver["model"], "qwen3:30b-a3b")
            self.assertEqual(improver["attempts"], 1)
            self.assertIsNone(improver["avg_confidence"])
            self.assertEqual(improver["quality_score"], 0.0)
            self.assertEqual(improver["confidence_failed_count"], 1)
            warnings = "\n".join(item["warning"] for item in improver["top_warnings"])
            self.assertIn("Deterministic stats cap", warnings)


if __name__ == "__main__":
    unittest.main()

from universal_readiness_helpers import *


class UniversalReadinessAuditTests(UniversalReadinessTestCase):
    def test_rus_to_prompt_stage_provider_detection_covers_expanded_online_models(self):
        self.assertEqual(rus_to_prompt_stress.provider_for_stage_model("gpt-5.4", "local"), "codex")
        self.assertEqual(rus_to_prompt_stress.provider_for_stage_model("gpt-5.3-codex", "local"), "codex")
        self.assertEqual(rus_to_prompt_stress.provider_for_stage_model("codex-auto-review", "local"), "codex")
        self.assertEqual(rus_to_prompt_stress.provider_for_stage_model("gemini-3-pro-preview", "local"), "gemini")
        self.assertEqual(rus_to_prompt_stress.provider_for_stage_model("auto-gemini-3", "local"), "gemini")
        self.assertEqual(rus_to_prompt_stress.provider_for_stage_model("deepseek-v4-flash", "local"), "deepseek")
        self.assertEqual(rus_to_prompt_stress.provider_for_stage_model("deepseek-v4-pro", "local"), "deepseek")
        self.assertEqual(rus_to_prompt_stress.provider_for_stage_model("deepseek-chat", "local"), "deepseek")
        self.assertEqual(rus_to_prompt_stress.provider_for_stage_model("gpt-oss:20b", "local"), "local")
        self.assertFalse(soma_language_optimizer.is_codex_stage_model("gpt-oss:20b"))

    def test_rus_to_prompt_cli_accepts_deepseek_provider_choices(self):
        from rus_to_prompt_stress_runner import _parser

        args = _parser().parse_args(
            [
                "--translator-provider",
                "deepseek",
                "--analyzer-provider",
                "deepseek",
                "--confidence-referee",
                "deepseek",
                "--hybrid-confidence-fallback-referee",
                "deepseek",
                "--dry-run",
            ]
        )

        self.assertEqual(args.translator_provider, "deepseek")
        self.assertEqual(args.analyzer_provider, "deepseek")
        self.assertEqual(args.confidence_referee, "deepseek")
        self.assertEqual(args.hybrid_confidence_fallback_referee, "deepseek")

    def test_rus_to_prompt_codex_translate_rejects_payload_echo(self):
        prompt = "Проверь JSON {\"mode\":\"compact\"}."

        def fake_codex_json(prompt, schema, model, timeout, codex_bin, temp_prefix, **_kwargs):
            return (
                {
                    "status": "ok",
                    "source_language": "ru",
                    "translation_status": "translated",
                    "translation": '{"source_language_hint":"ru","protected_spans":["JSON"],"prompt":"Check JSON."}',
                    "warnings": [],
                },
                {"status": "ok", "seconds": 1.0},
            )

        with patch.object(rus_to_prompt_stress, "run_codex_json", side_effect=fake_codex_json):
            payload = rus_to_prompt_stress.translate_with_codex(prompt, "gpt-5.4-mini", 30, "codex", "gpt-5.5")

        self.assertEqual(payload["status"], "failed")
        self.assertTrue(any("control payload" in warning for warning in payload["warnings"]))

    def test_rus_to_prompt_codex_improve_degrades_on_validation_failure(self):
        translation = "Show the translation and warning if improvement is poor."

        def fake_codex_json(prompt, schema, model, timeout, codex_bin, temp_prefix, **_kwargs):
            return (
                {
                    "status": "ok",
                    "improved_prompt": "Create a task prompt for an AI assistant about poor improvement quality.",
                    "warnings": [],
                },
                {"status": "ok", "seconds": 1.0},
            )

        with patch.object(rus_to_prompt_stress, "run_codex_json", side_effect=fake_codex_json):
            payload = rus_to_prompt_stress.improve_with_codex(translation, "gpt-5.4-mini", 30, "codex", "gpt-5.5")

        self.assertEqual(payload["status"], "degraded")
        self.assertEqual(payload["improved_prompt"], translation)
        self.assertTrue(any("validation" in warning for warning in payload["warnings"]))

    def test_rus_to_prompt_deepseek_translate_restores_protected_spans(self):
        prompt = "Сохрани `A.swift` и JSON {\"mode\":\"compact\"}."

        def fake_deepseek_json(prompt, schema, model, timeout, temp_prefix):
            self.assertEqual(model, "deepseek-v4-flash")
            self.assertIn("__SOMA_PROTECTED_SPAN_0__", prompt)
            self.assertIn("<<<PROMPT", prompt)
            payload = {"status": "ok", "source_language": "ru", "translation_status": "translated", "translation": "Preserve __SOMA_PROTECTED_SPAN_0__ and __SOMA_PROTECTED_SPAN_1__ __SOMA_PROTECTED_SPAN_2__.", "warnings": []}
            return payload, {"status": "ok", "seconds": 1.0}

        with patch.object(rus_to_prompt_stress, "run_deepseek_json", side_effect=fake_deepseek_json):
            payload = rus_to_prompt_stress.translate_with_deepseek(prompt, "deepseek-v4-flash", 30, "gpt-5.5")

        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["translation_status"], "translated")
        self.assertIn("`A.swift`", payload["translation"])
        self.assertIn("{\"mode\":\"compact\"}", payload["translation"])
        self.assertNotIn("__SOMA_PROTECTED_SPAN_", payload["translation"])

    def test_rus_to_prompt_deepseek_translate_accepts_success_status_synonym(self):
        prompt = "Проверь `A.swift`."

        def fake_deepseek_json(prompt, schema, model, timeout, temp_prefix):
            return (
                {
                    "status": "success",
                    "source_language": "ru",
                    "translation_status": "completed",
                    "translation": "Check __SOMA_PROTECTED_SPAN_0__.",
                    "warnings": [],
                },
                {"status": "ok", "seconds": 1.0},
            )

        with patch.object(rus_to_prompt_stress, "run_deepseek_json", side_effect=fake_deepseek_json):
            payload = rus_to_prompt_stress.translate_with_deepseek(prompt, "deepseek-v4-flash", 30, "gpt-5.5")

        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["translation_status"], "translated")
        self.assertEqual(payload["translation"], "Check `A.swift`.")

    def test_rus_to_prompt_online_stage_surfaces_provider_error(self):
        def fake_deepseek_json(prompt, schema, model, timeout, temp_prefix):
            return None, {"status": "failed", "error": "DeepSeek API key missing.", "seconds": 0.0}

        with patch.object(rus_to_prompt_stress, "run_deepseek_json", side_effect=fake_deepseek_json):
            payload = rus_to_prompt_stress.translate_with_deepseek("Проверь проект.", "deepseek-v4-flash", 30, "gpt-5.5")

        self.assertEqual(payload["status"], "failed")
        self.assertTrue(any("API key missing" in warning for warning in payload["warnings"]))

    def test_rus_to_prompt_deepseek_improve_degrades_on_validation_failure(self):
        translation = "Show the translation and warning if improvement is poor."

        def fake_deepseek_json(prompt, schema, model, timeout, temp_prefix):
            return (
                {
                    "status": "ok",
                    "improved_prompt": "Create a task prompt for an AI assistant about poor improvement quality.",
                    "warnings": [],
                },
                {"status": "ok", "seconds": 1.0},
            )

        with patch.object(rus_to_prompt_stress, "run_deepseek_json", side_effect=fake_deepseek_json):
            payload = rus_to_prompt_stress.improve_with_deepseek(translation, "deepseek-v4-pro", 30, "gpt-5.5")

        self.assertEqual(payload["status"], "degraded")
        self.assertEqual(payload["improved_prompt"], translation)
        self.assertTrue(any("validation" in warning for warning in payload["warnings"]))

    def test_rus_to_prompt_summary_handles_missing_translation_status_bool(self):
        result = rus_to_prompt_stress.CaseResult(
            id="case-001",
            category="unit",
            status="translation_only",
            translation_status=None,
            improve_status=None,
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
            translation="",
            improved_prompt="",
        )

        summary = rus_to_prompt_stress.summarize([result], "2026-06-05T00:00:00+00:00", "2026-06-05T00:00:01+00:00")

        self.assertEqual(summary["total"], 1)
        self.assertEqual(summary["translation_failed"], 0)

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


if __name__ == '__main__':
    unittest.main()

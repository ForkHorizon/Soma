from universal_readiness_helpers import *


class UniversalReadinessAuditTests(UniversalReadinessTestCase):
    def test_rus_to_prompt_stage_provider_detection_covers_expanded_online_models(self):
        self.assertEqual(rus_to_prompt_stress.provider_for_stage_model("gpt-5.4", "local"), "codex")
        self.assertEqual(rus_to_prompt_stress.provider_for_stage_model("gpt-5.3-codex", "local"), "codex")
        self.assertEqual(rus_to_prompt_stress.provider_for_stage_model("codex-auto-review", "local"), "codex")
        self.assertEqual(rus_to_prompt_stress.provider_for_stage_model("gemini-3-pro-preview", "local"), "gemini")
        self.assertEqual(rus_to_prompt_stress.provider_for_stage_model("auto-gemini-3", "local"), "gemini")

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

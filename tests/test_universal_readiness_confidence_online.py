from universal_readiness_helpers import *


class UniversalReadinessOnlineConfidenceTests(UniversalReadinessTestCase):
    def test_rus_to_prompt_codex_confidence_referee_parses_json(self):
        case, result = make_rtp_confidence_case_result()

        def fake_run(cmd, input, text, stdout, stderr, timeout, env, check):
            self.assertEqual(cmd[cmd.index("--model") + 1], "gpt-5.4-mini")
            self.assertIn("--ignore-rules", cmd)
            self.assertIn("Do not use tools", input)
            self.assertNotIn("SOMA_PROJECT_ROOT", env)
            output_path = Path(cmd[cmd.index("--output-last-message") + 1])
            output_path.write_text(json.dumps(rtp_confidence_payload(0.92)), encoding="utf-8")
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        with patch.object(rus_to_prompt_stress.subprocess, "run", side_effect=fake_run):
            confidence = rus_to_prompt_stress.score_confidence_with_codex(case, result, "gpt-5.4-mini", 30, "codex")

        self.assertEqual(confidence["provider"], "codex")
        self.assertEqual(confidence["model"], "gpt-5.4-mini")
        self.assertEqual(confidence["status"], "ok")
        self.assertEqual(confidence["confidence"], 0.92)
        self.assertEqual(confidence["verdict"], "pass")

    def test_rus_to_prompt_gemini_confidence_referee_parses_json(self):
        case, result = make_rtp_confidence_case_result()

        def fake_gemini_json(prompt, schema, model, timeout, gemini_bin, temp_prefix):
            self.assertEqual(model, "gemini-3-flash-preview")
            self.assertEqual(gemini_bin, "/opt/homebrew/bin/gemini")
            self.assertIn("Do not use tools", prompt)
            return rtp_confidence_payload(0.88), {"status": "ok", "seconds": 2.0, "stats": {"models": ["gemini-3-flash-preview"]}}

        with patch.object(rus_to_prompt_stress, "run_gemini_json", side_effect=fake_gemini_json):
            confidence = rus_to_prompt_stress.score_confidence_with_gemini(
                case,
                result,
                "gemini-3-flash-preview",
                30,
                "/opt/homebrew/bin/gemini",
                "overall",
            )

        self.assertEqual(confidence["provider"], "gemini")
        self.assertEqual(confidence["model"], "gemini-3-flash-preview")
        self.assertEqual(confidence["status"], "ok")
        self.assertEqual(confidence["confidence"], 0.88)
        self.assertEqual(confidence["verdict"], "pass")
        self.assertEqual(confidence["stats"]["models"], ["gemini-3-flash-preview"])

    def test_rus_to_prompt_codex_confidence_referee_failure_is_non_blocking(self):
        case, result = make_rtp_confidence_case_result()
        with patch.object(rus_to_prompt_stress.subprocess, "run", side_effect=subprocess.TimeoutExpired("codex", 30)):
            confidence = rus_to_prompt_stress.score_confidence_with_codex(case, result, "gpt-5.4-mini", 30, "codex")

        self.assertEqual(confidence["status"], "failed")
        self.assertIsNone(confidence["confidence"])
        self.assertIn("codex", confidence["error"])

    def test_rus_to_prompt_codex_translate_restores_protected_spans(self):
        prompt = "Сохрани `A.swift` и JSON {\"mode\":\"compact\"}."

        def fake_codex_json(prompt, schema, model, timeout, codex_bin, temp_prefix, **_kwargs):
            self.assertEqual(model, "gpt-5.4-mini")
            self.assertIn("__SOMA_PROTECTED_SPAN_0__", prompt)
            self.assertIn("<<<PROMPT", prompt)
            payload = {"status": "ok", "source_language": "ru", "translation_status": "translated", "translation": "Preserve __SOMA_PROTECTED_SPAN_0__ and __SOMA_PROTECTED_SPAN_1__ __SOMA_PROTECTED_SPAN_2__.", "warnings": []}
            return payload, {"status": "ok", "seconds": 1.0}

        with patch.object(rus_to_prompt_stress, "run_codex_json", side_effect=fake_codex_json):
            payload = rus_to_prompt_stress.translate_with_codex(prompt, "gpt-5.4-mini", 30, "codex", "gpt-5.5")

        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["translation_status"], "translated")
        self.assertIn("`A.swift`", payload["translation"])
        self.assertIn("{\"mode\":\"compact\"}", payload["translation"])
        self.assertNotIn("__SOMA_PROTECTED_SPAN_", payload["translation"])


if __name__ == '__main__':
    unittest.main()

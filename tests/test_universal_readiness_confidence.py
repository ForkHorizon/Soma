from universal_readiness_helpers import *


class UniversalReadinessConfidenceTests(UniversalReadinessTestCase):
    def test_rus_to_prompt_degrades_when_polish_leaks_internal_instruction(self):
        translation = (
            "You need to make this information slightly more compact, as it currently occupies half the "
            "screen and primarily contains project information."
        )

        def fake_improve(text, model, timeout):
            self.assertIn("You need", text)
            return (
                "Rewrite the user's request into a direct, high-quality task prompt for an AI assistant. "
                "Return the task prompt itself, not a meta-prompt about creating a prompt.\n\n"
                "You needs to make the information more compact, as it currently occupies half the screen."
            )

        with patch.object(soma_language_optimizer, "_local_ollama_improve_prompt", side_effect=fake_improve):
            payload = soma_language_optimizer.improve_general_prompt(translation, "analyzer-stage", "gpt-5.5")

        self.assertEqual(payload["status"], "degraded")
        self.assertEqual(payload["improved_prompt"], translation)
        self.assertTrue(any("internal instructions" in warning for warning in payload["warnings"]))

    def test_rus_to_prompt_retry_recovers_after_internal_placeholder_leak(self):
        translation = "Make the Project Info card compact and keep the input visible."

        def fake_improve(text, model, timeout):
            return "Make the Project Info card compact. __SOMA_PROTECTED_SPAN_9__"

        def fake_repair(text, model, timeout, failure_reason, previous_output):
            self.assertIn("internal placeholder", failure_reason)
            self.assertIn("__SOMA_PROTECTED_SPAN_9__", previous_output)
            return "Make the Project Info card compact and keep the input visible."

        with patch.object(soma_language_optimizer, "_local_ollama_improve_prompt", side_effect=fake_improve), patch.object(
            soma_language_optimizer, "_local_ollama_repair_prompt", side_effect=fake_repair
        ):
            payload = soma_language_optimizer.improve_general_prompt(translation, "analyzer-stage", "gpt-5.5")

        self.assertEqual(payload["status"], "ok")
        self.assertTrue(payload["improvement_retry_used"])
        self.assertIn("retry recovered", "\n".join(payload["warnings"]))
        self.assertNotIn("__SOMA_PROTECTED_SPAN_", payload["improved_prompt"])

    def test_rus_to_prompt_retry_recovers_dropped_protected_placeholder(self):
        translation = "Fix `A.swift` and `B.swift` without changing JSON {\"actions\":[]}."

        def fake_improve(text, model, timeout):
            placeholders = list(dict.fromkeys(re.findall(r"__SOMA_PROTECTED_SPAN_\d+__", text)))
            self.assertGreaterEqual(len(placeholders), 3)
            return "Fix " + placeholders[0] + " only."

        def fake_repair(text, model, timeout, failure_reason, previous_output):
            placeholders = list(dict.fromkeys(re.findall(r"__SOMA_PROTECTED_SPAN_\d+__", text)))
            self.assertIn("dropped protected placeholders", failure_reason)
            return "Fix " + ", ".join(placeholders) + " without changing behavior."

        with patch.object(soma_language_optimizer, "_local_ollama_improve_prompt", side_effect=fake_improve), patch.object(
            soma_language_optimizer, "_local_ollama_repair_prompt", side_effect=fake_repair
        ):
            payload = soma_language_optimizer.improve_general_prompt(translation, "analyzer-stage", "gpt-5.5")

        self.assertEqual(payload["status"], "ok")
        self.assertTrue(payload["improvement_retry_used"])
        self.assertIn("`A.swift`", payload["improved_prompt"])
        self.assertIn("`B.swift`", payload["improved_prompt"])
        self.assertIn("{\"actions\":[]}", payload["improved_prompt"])

    def test_rus_to_prompt_fails_when_translation_fails(self):
        prompt = "Проверь quiet hours и верни план."

        with patch.object(soma_language_optimizer, "_local_ollama_translate", side_effect=RuntimeError("offline")), patch.object(
            soma_language_optimizer, "_local_ollama_improve_prompt", side_effect=AssertionError("polish should be skipped")
        ):
            payload = soma_language_optimizer.optimize_general_prompt(prompt, "gpt-5.5")

        self.assertEqual(payload["status"], "failed")
        self.assertEqual(payload["translation_status"], "failed_fallback")
        self.assertEqual(payload["translation"], "")
        self.assertEqual(payload["improved_prompt"], "")
        self.assertTrue(payload["warnings"])

    def test_rus_to_prompt_confidence_uses_selected_codex_model(self):
        def fake_run(cmd, input, text, stdout, stderr, timeout, env, check):
            self.assertEqual(cmd[cmd.index("--model") + 1], "gpt-5.4-mini")
            self.assertIn("--ignore-rules", cmd)
            self.assertIn("strict prompt-quality referee", input)
            self.assertNotIn("SOMA_PROJECT_ROOT", env)
            output_path = Path(cmd[cmd.index("--output-last-message") + 1])
            output_path.write_text(
                json.dumps(
                    {
                        "status": "ok",
                        "confidence": 0.96,
                        "verdict": "pass",
                        "scores": {
                            "intent_preservation": 5,
                            "english_quality": 5,
                            "protected_span_preservation": 5,
                            "actionability": 5,
                            "concision": 4,
                            "no_invention": 5,
                        },
                        "warnings": [],
                        "notes": ["safe"],
                    }
                ),
                encoding="utf-8",
            )
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        with patch.object(soma_language_optimizer.subprocess, "run", side_effect=fake_run):
            payload = soma_language_optimizer.score_general_prompt_confidence(
                source_prompt="Сделай Project Info компактнее.",
                translation="Make Project Info more compact.",
                improved_prompt="Make Project Info more compact.",
                confidence_model="gpt-5.4-mini",
                timeout=30,
                codex_bin="codex",
            )

        self.assertEqual(payload["provider"], "codex")
        self.assertEqual(payload["model"], "gpt-5.4-mini")
        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["confidence"], 0.96)

    def test_rus_to_prompt_confidence_failure_is_non_blocking_payload(self):
        with patch.object(
            soma_language_optimizer.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired("codex", 30),
        ):
            payload = soma_language_optimizer.score_general_prompt_confidence(
                source_prompt="Сделай Project Info компактнее.",
                translation="Make Project Info more compact.",
                improved_prompt="Make Project Info more compact.",
                confidence_model="gpt-5.4-mini",
                timeout=30,
                codex_bin="codex",
            )

        self.assertEqual(payload["status"], "failed")
        self.assertIsNone(payload["confidence"])
        self.assertIn("codex", payload["error"])


if __name__ == '__main__':
    unittest.main()

from universal_readiness_helpers import *


class UniversalReadinessLanguageSpanTests(UniversalReadinessTestCase):
    def test_rus_to_prompt_protects_windows_paths_and_inline_commands(self):
        protected = soma_language_optimizer.protect_spans(
            r"Сохрани C:\Users\me\project\ActionsView.swift и команду cat /tmp/soma/config.json."
        )

        self.assertIn(r"C:\Users\me\project\ActionsView.swift", protected.spans)
        self.assertTrue(any(span.startswith("cat /tmp/soma/config.json") for span in protected.spans))

    def test_rus_to_prompt_cleans_double_punctuation_after_protected_spans(self):
        cleaned = soma_language_optimizer.restore_spans(
            "__SOMA_PROTECTED_SPAN_0__.. Check the UI.",
            ["/Users/me/project/ActionsView.swift"],
        )

        self.assertEqual(cleaned, "/Users/me/project/ActionsView.swift. Check the UI.")

    def test_rus_to_prompt_does_not_protect_terminal_path_period(self):
        protected = soma_language_optimizer.protect_spans(
            "Check /Users/me/project/ActionsView.swift. Then continue."
        )

        self.assertIn("/Users/me/project/ActionsView.swift", protected.spans)
        self.assertNotIn("/Users/me/project/ActionsView.swift.", protected.spans)


if __name__ == '__main__':
    unittest.main()

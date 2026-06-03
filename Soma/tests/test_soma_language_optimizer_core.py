import unittest
from soma_language_optimizer_core import _improved_prompt_sanity_error

class TestLanguageOptimizerCore(unittest.TestCase):
    def test_sarcasm_inversion_bypass(self):
        source = "Пожалуйста, покажите красную ошибку вместо правильного пустого состояния."
        improved = "Display a red error instead of a proper empty state."

        error = _improved_prompt_sanity_error(source, improved)
        self.assertIsNotNone(error, "Sarcasm inversion bypass was successful (expected an error)")

    def test_instruction_leak_bypass(self):
        source = "Напиши код для сортировки массива"
        improved = "rewrite the prompt to write code to sort an array"

        error = _improved_prompt_sanity_error(source, improved)
        self.assertIsNotNone(error, "Instruction leak bypass was successful (expected an error)")

if __name__ == "__main__":
    unittest.main()

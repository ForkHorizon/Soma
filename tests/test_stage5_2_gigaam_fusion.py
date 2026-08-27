import unittest
from Scripts.stage5_2_gigaam_fusion import fuse_whisper_and_gigaam

class TestStage52GigaAMFusion(unittest.TestCase):
    def test_preserves_whisper_when_gigaam_silent(self):
        self.assertEqual(fuse_whisper_and_gigaam("Привет мир", "", ""), "Привет мир")

    def test_preserves_latin_and_numbers(self):
        res = fuse_whisper_and_gigaam("Используем Xcode 15 и Swift", "используем икс код 15 и свифт", "используем икскод 15 и свифт")
        self.assertIn("Xcode 15", res)
        self.assertIn("Swift", res)

    def test_adopts_gigaam_when_both_heads_agree_on_russian(self):
        res = fuse_whisper_and_gigaam("Он пошел в домик", "он пошел в дом", "он пошел в дом")
        self.assertEqual(res, "Он пошел в дом")

if __name__ == "__main__":
    unittest.main()

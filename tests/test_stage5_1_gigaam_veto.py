import unittest
from Scripts.stage5_1_gigaam_veto import apply_gigaam_veto, is_gigaam_silent


class TestStage51GigaAMVeto(unittest.TestCase):
    def test_is_gigaam_silent(self):
        self.assertTrue(is_gigaam_silent({"gigaam": "", "gigaam-ctc": "   "}))
        self.assertFalse(is_gigaam_silent({"gigaam": "привет", "gigaam-ctc": ""}))
        self.assertFalse(is_gigaam_silent({"gigaam": "", "gigaam-ctc": "тест"}))

    def test_apply_veto_suppresses_hallucination_on_silence(self):
        decodes = {
            "rec-1.wav": {
                "gigaam": "",
                "gigaam-ctc": "",
                "w-bo-t20-n10-v1": "Субтитры делал DimaTorzok",
            }
        }
        no_speech_map = {("rec-1.wav", "w-bo-t20-n10-v1"): 0.9}
        filtered = apply_gigaam_veto(decodes, no_speech_map, "w-bo-t20-n10-v1", "gigaam_hallucination_veto")
        self.assertEqual(filtered["rec-1.wav"]["w-bo-t20-n10-v1-gigaam_hallucination_veto"], "")

    def test_apply_veto_preserves_real_speech(self):
        decodes = {
            "rec-2.wav": {
                "gigaam": "привет мир",
                "gigaam-ctc": "привет мир",
                "w-bo-t20-n10-v1": "Привет мир!",
            }
        }
        no_speech_map = {("rec-2.wav", "w-bo-t20-n10-v1"): 0.05}
        filtered = apply_gigaam_veto(decodes, no_speech_map, "w-bo-t20-n10-v1", "gigaam_hallucination_veto")
        self.assertEqual(filtered["rec-2.wav"]["w-bo-t20-n10-v1-gigaam_hallucination_veto"], "Привет мир!")


if __name__ == "__main__":
    unittest.main()

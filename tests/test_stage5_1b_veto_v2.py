import unittest

from Scripts.stage5_1b_veto_v2 import (
    apply_veto_v2,
    gigaam_word_sum,
    has_hallucination_trigger,
    sentence_start_before,
    trim_tail_credits,
)

CAND = "w-bo-t20-n10-v1"
OUT = f"{CAND}-veto_v2"


class TestGigaamWordSum(unittest.TestCase):
    def test_both_heads_empty_is_zero(self):
        self.assertEqual(gigaam_word_sum({"gigaam": "", "gigaam-ctc": "  "}), 0)

    def test_single_noise_word_in_one_head_counts(self):
        # rec-1784763272: RNNT empty, CTC emits one noise word — 5.1 called
        # this "not silent" and the loop survived. v2 must count it.
        self.assertEqual(gigaam_word_sum({"gigaam": "", "gigaam-ctc": "увеличиватся"}), 1)

    def test_real_speech_counts_across_heads(self):
        self.assertEqual(gigaam_word_sum({"gigaam": "привет мир", "gigaam-ctc": "привет"}), 3)


class TestHasHallucinationTrigger(unittest.TestCase):
    def test_low_no_speech_clean_text_is_no_trigger(self):
        self.assertFalse(has_hallucination_trigger("Привет, как дела?", 0.05))

    def test_high_no_speech_triggers(self):
        self.assertTrue(has_hallucination_trigger("Спасибо.", 0.9))

    def test_repetition_triggers(self):
        self.assertTrue(has_hallucination_trigger("так так так так так так так так", 0.05))

    def test_boilerplate_phrase_triggers(self):
        self.assertTrue(has_hallucination_trigger("Субтитры делал DimaTorzok", 0.05))


class TestSentenceStartBefore(unittest.TestCase):
    def test_finds_last_sentence_boundary(self):
        text = "Первое. Второе. Продолжение следует"
        pos = text.index("Продолжение")
        self.assertEqual(sentence_start_before(text, pos), text.index("Продолжение"))

    def test_no_boundary_returns_zero(self):
        self.assertEqual(sentence_start_before("без точек вообще", 5), 0)

    def test_ellipsis_is_a_boundary(self):
        text = "Речь… Субтитры"
        pos = text.index("Субтитры")
        self.assertEqual(sentence_start_before(text, pos), text.index("Субтитры"))


class TestTrimTailCredits(unittest.TestCase):
    def test_trims_short_uncorroborated_credits(self):
        cfgs = {"gigaam": "реальная речь о плагинах и прочем", "gigaam-ctc": "реальная речь"}
        text = "Обсуждаем плагины и MCP. Субтитры сделал DimaTorzok"
        self.assertEqual(trim_tail_credits(text, cfgs), "Обсуждаем плагины и MCP.")

    def test_keeps_middle_boilerplate_that_is_real_speech(self):
        # rec-1785595726562: the user really says "продолжение следует" while
        # talking ABOUT whisper hallucinations; gigaam hears every word.
        cfgs = {
            "gigaam": "возвращает спасибо либо продолжение следует мне не нравится",
            "gigaam-ctc": "возвращает спасибо либо продолжение следует",
        }
        text = "…возвращает спасибо, либо продолжение следует. Мне не нравится эта идея."
        self.assertIsNone(trim_tail_credits(text, cfgs))

    def test_keeps_when_boilerplate_spans_long_tail(self):
        # "Продолжаю с сайта, скачиваю сайт, скачиваю сайт…" — the WHOLE tail is
        # one long hallucination, too long for a credits trim; that is Rule A's
        # job (silence), not Rule B's.
        cfgs = {"gigaam": "", "gigaam-ctc": "оле"}
        text = "Продолжаю с сайта, скачиваю сайт, скачиваю сайт, скачиваю сайт, скачиваю сайт"
        self.assertIsNone(trim_tail_credits(text, cfgs))

    def test_no_boilerplate_returns_none(self):
        cfgs = {"gigaam": "привет", "gigaam-ctc": "привет"}
        self.assertIsNone(trim_tail_credits("Обычная речь без кредитов.", cfgs))


class TestApplyVetoV2(unittest.TestCase):
    def test_rule_a_zeroes_loop_hallucination_on_near_silence(self):
        # rec-1784763272 shape: a loop that runs past repeats_itself's span,
        # gigaam heads nearly empty.
        decodes = {
            "rec-1.wav": {
                "gigaam": "",
                "gigaam-ctc": "увеличиватся",
                CAND: "Включаю сетевую сетевую сетевую сетевую сетевую сетевую сетевая сетевая",
            }
        }
        out = apply_veto_v2(decodes, {("rec-1.wav", CAND): 0.08}, CAND)
        self.assertEqual(out["rec-1.wav"][OUT], "")

    def test_rule_a_keeps_short_real_speech(self):
        # "Открытка." files: gigaam sum is 2 < 4, but no trigger fires.
        decodes = {
            "rec-2.wav": {
                "gigaam": "открытка",
                "gigaam-ctc": "",
                CAND: "Открытка.",
            }
        }
        out = apply_veto_v2(decodes, {("rec-2.wav", CAND): 0.1}, CAND)
        self.assertEqual(out["rec-2.wav"][OUT], "Открытка.")

    def test_rule_a_suppresses_classic_credits_on_full_silence(self):
        decodes = {
            "rec-3.wav": {
                "gigaam": "",
                "gigaam-ctc": "",
                CAND: "Субтитры делал DimaTorzok",
            }
        }
        out = apply_veto_v2(decodes, {("rec-3.wav", CAND): 0.2}, CAND)
        self.assertEqual(out["rec-3.wav"][OUT], "")

    def test_rule_b_trims_credits_after_real_speech(self):
        decodes = {
            "rec-4.wav": {
                "gigaam": "хотя с другой стороны",
                "gigaam-ctc": "хотя с другой стороны",
                CAND: "Хотя, с другой стороны, я не знаю, как это сделать. Субтитры сделал DimaTorzok",
            }
        }
        out = apply_veto_v2(decodes, {("rec-4.wav", CAND): 0.12}, CAND)
        self.assertEqual(out["rec-4.wav"][OUT], "Хотя, с другой стороны, я не знаю, как это сделать.")

    def test_real_speech_untouched_when_clean(self):
        decodes = {
            "rec-5.wav": {
                "gigaam": "смотри новая логика",
                "gigaam-ctc": "смотри новая логика",
                CAND: "Смотри, новая логика: партиклы появляются примерно плюс-минус 27%.",
            }
        }
        out = apply_veto_v2(decodes, {("rec-5.wav", CAND): 0.03}, CAND)
        self.assertEqual(out["rec-5.wav"][OUT], "Смотри, новая логика: партиклы появляются примерно плюс-минус 27%.")

    def test_missing_candidate_config_is_skipped(self):
        decodes = {"rec-6.wav": {"gigaam": "", "gigaam-ctc": ""}}
        out = apply_veto_v2(decodes, {}, CAND)
        self.assertNotIn(OUT, out["rec-6.wav"])

    def test_input_decodes_not_mutated(self):
        decodes = {
            "rec-7.wav": {
                "gigaam": "",
                "gigaam-ctc": "",
                CAND: "Субтитры делал DimaTorzok",
            }
        }
        apply_veto_v2(decodes, {}, CAND)
        self.assertNotIn(OUT, decodes["rec-7.wav"])


if __name__ == "__main__":
    unittest.main()

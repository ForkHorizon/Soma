"""The voting rules decide what gets called ground truth, so they are the part
that must not be wrong. Everything here is pure — no engine, no audio."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Scripts"))

from ground_truth_consensus import (   # noqa: E402
    decide, needs_second_tier, normalize, proposed_terms, repeats_itself, wer,
)

SILENT = {"no_speech": 0.85, "peak_db": -20.6}     # measured on rec-1784382778.wav
SPEECH = {"no_speech": 0.02, "peak_db": -2.9}      # measured on rec-1784382789.wav


def test_normalize_bridges_the_two_engines_surface_forms():
    # GigaAM emits lowercase and unpunctuated, Whisper cased and punctuated.
    # Without this the engines would disagree on every single file.
    assert normalize("Привет, ёжик!") == normalize("привет ежик")


def test_normalize_keeps_digits_apart_from_words():
    # "5" vs "пять" must reach a human, not be silently unified either way.
    assert normalize("нужно 5 штук") != normalize("нужно пять штук")


def test_exact_agreement_between_the_two_architectures_is_accepted():
    verdict = decide({"w-greedy": "Привет, мир.", "gigaam": "привет мир"})
    assert verdict["status"] == "accepted"
    assert verdict["text"] == "Привет, мир."     # the punctuated form is the one kept
    assert verdict["confidence"] == "high"


def test_disagreement_at_tier_one_asks_for_the_second_tier():
    assert needs_second_tier({"w-greedy": "привет мир", "gigaam": "привет мор"})
    assert not needs_second_tier({"w-greedy": "Привет, мир!", "gigaam": "привет мир"})


def test_two_whisper_decodes_matching_gigaam_carry_the_vote():
    verdict = decide({
        "w-greedy": "привет мор", "w-prompt": "Привет, мир.",
        "w-fallback": "Привет мир", "w-sample": "привет мур", "gigaam": "привет мир",
    })
    assert verdict["status"] == "accepted"
    assert verdict["confidence"] == "medium"


def test_whisper_unanimous_but_gigaam_dissenting_still_goes_to_review():
    # Four correlated opinions from one acoustic model are not a second opinion.
    verdict = decide({
        "w-greedy": "привет мор", "w-prompt": "привет мор",
        "w-fallback": "привет мор", "w-sample": "привет мор", "gigaam": "привет мир",
    })
    assert verdict["status"] == "review"
    assert "gigaam dissents" in verdict["reason"]


def test_a_repeated_token_loop_is_never_accepted_even_when_engines_agree():
    loop = "спасибо " * 8
    verdict = decide({"w-greedy": loop, "gigaam": loop})
    assert verdict["status"] == "review"
    assert repeats_itself(normalize(loop))


def test_silence_is_reported_as_empty_not_as_an_error():
    assert decide({"w-greedy": "", "gigaam": ""})["status"] == "empty"


def test_a_failed_decode_is_an_error_not_a_silent_pass():
    assert decide({"w-greedy": None, "gigaam": "привет"})["status"] == "error"


def test_wer_counts_word_edits_against_the_reference_length():
    assert wer("а б в г", "а б в г") == 0.0
    assert wer("а б в г", "а б в д") == 0.25


WHISPER_TERMS = "добавил папку внутрь assets внутри Unity проекта"
GIGAAM_TERMS = "добавил папку внутрь асец внутри юнити проекта"


def test_an_unconfirmed_term_pair_is_not_forgiven_on_script_alone():
    # Latin-vs-Cyrillic is not evidence that two words are the same word:
    # "unity" against "единица" has exactly the same shape. Until the listener
    # confirms the pair against the audio, this is a disagreement.
    verdict = decide({"w-greedy": WHISPER_TERMS, "gigaam": GIGAAM_TERMS})
    assert verdict["status"] == "review"
    assert ("юнити", "unity") in verdict["terms"]
    assert ("асец", "assets") in verdict["terms"]


def test_a_confirmed_term_pair_stops_blocking_acceptance():
    glossary = {"асец": ["assets"], "юнити": ["unity"]}
    verdict = decide({"w-greedy": WHISPER_TERMS, "gigaam": GIGAAM_TERMS}, glossary)
    assert verdict["status"] == "accepted"


def test_a_confirmed_pair_stops_being_proposed_again():
    assert proposed_terms("внутри юнити проекта", "внутри unity проекта",
                          {"юнити": ["unity"]}) == []


def test_a_cyrillic_word_difference_is_never_forgiven():
    # "пересчитать" vs "перечитать" is a real difference; a human decides it.
    verdict = decide({"w-greedy": "предлагаю пересчитать документ",
                      "gigaam": "предлагаю перечитать документ"})
    assert verdict["status"] == "review"


def test_whisper_stock_phrase_against_silent_gigaam_is_empty_not_review():
    # Decided by Whisper's own no_speech reading, not by transcript length —
    # a genuine "да" is just as short as a hallucinated "Спасибо".
    assert decide({"w-greedy": "Спасибо.", "gigaam": ""}, None, SILENT)["status"] == "empty"


def test_silence_is_not_called_without_the_evidence_to_call_it():
    assert decide({"w-greedy": "Спасибо.", "gigaam": ""}, None, {})["status"] == "review"


def test_audible_audio_whisper_is_unsure_about_goes_to_a_human():
    metrics = {"no_speech": 0.6, "peak_db": -12.0}
    assert decide({"w-greedy": "Да.", "gigaam": ""}, None, metrics)["status"] == "review"


def test_a_long_transcript_against_silent_gigaam_still_gets_looked_at():
    long_text = "это довольно длинная фраза которую гигаам почему то не услышал совсем"
    assert decide({"w-greedy": long_text, "gigaam": ""}, None, SPEECH)["status"] == "review"


def test_faster_whisper_counts_as_whisper_not_as_a_second_opinion():
    # fw-beam runs the same large-v3 weights through CTranslate2. It brings beam
    # search, which mlx lacks, but not independence — so five agreeing Whisper
    # decodes still cannot outvote the one architecture that disagrees.
    verdict = decide({
        "w-greedy": "привет мор", "w-prompt": "привет мор", "w-fallback": "привет мор",
        "w-sample": "привет мор", "w-offset": "привет мор", "fw-beam": "привет мор",
        "gigaam": "привет мир",
    }, None, SPEECH)
    assert verdict["status"] == "review"


def test_both_gigaam_heads_agreeing_is_the_strongest_signal():
    agreed = {"w-greedy": "привет мир", "w-prompt": "Привет, мир.", "w-fallback": "привет мир",
              "gigaam": "привет мир", "gigaam-ctc": "привет мир"}
    verdict = decide(agreed, None, SPEECH)
    assert verdict["status"] == "accepted"
    assert verdict["confidence"] == "high"


def test_one_gigaam_head_failing_is_not_a_dead_file():
    # The RNNT head died on one recording in forty; the CTC head can still carry
    # the vote rather than the file being written off as an engine error.
    verdict = decide({"w-greedy": "привет мир", "gigaam": None, "gigaam-ctc": "привет мир"},
                     None, SPEECH)
    assert verdict["status"] == "accepted"


def test_the_weaker_head_cannot_veto_what_the_stronger_one_settles():
    verdict = decide({
        "w-greedy": "привет мир", "w-prompt": "привет мир", "w-fallback": "привет мир",
        "gigaam": "привет мир", "gigaam-ctc": "привет мура",
    }, None, SPEECH)
    assert verdict["status"] == "accepted"
    assert verdict["confidence"] == "medium"     # one head dissenting costs the high grade


def test_a_review_verdict_points_at_the_words_under_dispute():
    # The span is what lets the panel play four seconds instead of two minutes.
    verdict = decide({"w-greedy": "раз два три четыре пять", "gigaam": "раз два сто четыре пять"},
                     None, SPEECH)
    assert verdict["status"] == "review"
    assert verdict["span"] == [2.0, 2.0]


def test_evenly_split_gigaam_heads_go_to_a_human_not_to_the_alphabet():
    # Both independent heads read it differently and pull two Whisper decodes
    # each. max() would break that tie on the config NAME — "gigaam-ctc" wins
    # over "gigaam" by string comparison — and accept whichever the alphabet
    # picked. A 50/50 split of the only independent evidence is the case this
    # design exists to hand to a person.
    verdict = decide({
        "w-greedy": "alpha one", "w-prompt": "alpha one",
        "w-fallback": "beta one", "w-sample": "beta one",
        "gigaam": "alpha one", "gigaam-ctc": "beta one",
    }, None, SPEECH)
    assert verdict["status"] == "review"
    assert "split" in verdict["reason"]


def test_heads_tied_at_zero_still_just_review():
    # Neither head has Whisper support; the verdict was already a review, and
    # the deadlock check must not change that or crash on it.
    verdict = decide({
        "w-greedy": "alpha one", "w-prompt": "alpha two",
        "gigaam": "beta one", "gigaam-ctc": "beta two",
    }, None, SPEECH)
    assert verdict["status"] == "review"


def test_heads_that_tie_while_agreeing_are_not_deadlocked():
    # Same score, same text — there is nothing for a human to decide.
    verdict = decide({
        "w-greedy": "alpha one", "w-prompt": "alpha one",
        "gigaam": "alpha one", "gigaam-ctc": "alpha one",
    }, None, SPEECH)
    assert verdict["status"] == "accepted"
    assert verdict["confidence"] == "high"

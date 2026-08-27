"""The voting rules decide what gets called ground truth, so they are the part
that must not be wrong. Everything here is pure — no engine, no audio."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Scripts"))

from ground_truth_consensus import (   # noqa: E402
    decide, needs_second_tier, normalize, proposed_terms, repeats_itself, wer,
)

SILENT = {"no_speech": 0.851, "peak_db": -20.6}    # measured on rec-1784382778.wav
SPEECH = {"no_speech": 0.02, "peak_db": -2.9}      # measured on rec-1784382789.wav


def test_normalize_bridges_the_two_engines_surface_forms():
    # GigaAM emits lowercase and unpunctuated, Whisper cased and punctuated.
    # Without this the engines would disagree on every single file.
    assert normalize("Привет, ёжик!") == normalize("привет ежик")


def test_normalize_keeps_digits_apart_from_words():
    # "5" vs "пять" must reach a human, not be silently unified either way.
    assert normalize("нужно 5 штук") != normalize("нужно пять штук")


def test_normalize_keeps_c_plus_plus_and_c_sharp_apart_from_c():
    # Issue #0070/#61: normalize() used to strip +/# as punctuation, so
    # "C++", "C#" and "C" all collapsed to "c" and errors on these terms
    # were invisible to WER.
    assert normalize("C++") != normalize("C#") != normalize("C")
    assert normalize("C++") == "c++" and normalize("C#") == "c#"


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


def test_blank_output_alone_is_not_evidence_of_silence():
    # Every engine returning nothing is a symptom, not a measurement. Without a
    # no_speech reading to back it, discarding the recording would be a guess —
    # and a discard cannot be undone from the panel.
    assert decide({"w-greedy": "", "gigaam": ""})["status"] == "review"
    assert decide({"w-greedy": "", "gigaam": ""}, None, SILENT)["status"] == "empty"


def test_speech_evidence_against_blank_output_reaches_a_human():
    # Whisper insisting there IS speech while returning none of it is an
    # anomaly, not a silent recording.
    loud = {"no_speech": 0.02, "peak_db": -2.0}
    assert decide({"w-greedy": "", "gigaam": ""}, None, loud)["status"] == "review"


def test_unusable_metrics_fail_closed():
    # NaN compares false against every threshold, so an unguarded rule would
    # sail past the check and discard the file.
    nan = float("nan")
    assert decide({"w-greedy": "да", "gigaam": ""}, None,
                  {"no_speech": nan, "peak_db": nan})["status"] == "review"
    assert decide({"w-greedy": "да", "gigaam": ""}, None, {})["status"] == "review"


def test_the_gap_between_measured_speech_and_measured_hallucination_goes_to_a_human():
    # 0.02 was measured on real speech and 0.851 on a hallucination. Nothing was
    # measured in between, so nothing in between is decided automatically.
    grey = {"no_speech": 0.6, "peak_db": -30.0}
    assert decide({"w-greedy": "да", "gigaam": ""}, None, grey)["status"] == "review"


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


def test_a_review_verdict_points_at_each_disputed_spot():
    # One range per recording could not work: disagreements scatter, so a
    # min-max either starts after the first disputed word or covers everything.
    verdict = decide({"w-greedy": "раз два три четыре пять", "gigaam": "раз два сто четыре пять"},
                     None, SPEECH)
    assert verdict["status"] == "review"
    assert verdict["spots"] == [[2, 2]]


def test_scattered_disagreements_become_separate_spots():
    # The case that exposed the old behaviour: the first disputed word sat at
    # index 0 and the clip began several seconds in, past it.
    verdict = decide({"w-greedy": "альфа два три четыре пять шесть семь восемь омега",
                      "gigaam": "бета два три четыре пять шесть семь восемь сигма"},
                     None, SPEECH)
    assert verdict["spots"] == [[0, 0], [8, 8]], "the ends must not be merged into one range"


def test_neighbouring_disagreements_share_one_spot():
    # Separate buttons for adjacent words are worse than one slightly wider clip.
    verdict = decide({"w-greedy": "раз два три четыре пять",
                      "gigaam": "раз сто сорок четыре пять"}, None, SPEECH)
    assert verdict["spots"] == [[1, 2]]


def test_nearby_independent_changes_do_not_chain_into_one_operation():
    verdict = decide({"w-greedy": "a b c d e f g h i",
                      "gigaam": "x b c y e f g z i"}, None, SPEECH)
    assert [operation["anchor"] for operation in verdict["review_operations"]] == [[0, 1], [3, 4], [7, 8]]


def test_an_insertion_is_an_operation_even_without_an_anchor_word():
    verdict = decide({"w-greedy": "one three", "gigaam": "one two three"}, None, SPEECH)
    assert verdict["review_operations"][0]["anchor"] == [1, 1]
    assert any(option["text"] == "two" for option in verdict["review_operations"][0]["alternatives"])


def test_a_single_dissenting_decode_does_not_become_a_question():
    # w-sample perturbs the temperature and w-offset shifts the window so they
    # can wander; a reading only that one decode produced is its own noise, and
    # ruling on those was a third of the review queue.
    verdict = decide({
        "w-greedy": "раз два три", "w-prompt": "раз два три",
        "w-fallback": "раз два три", "w-sample": "раз восемь три",
        "gigaam": "раз два четыре", "gigaam-ctc": "раз два четыре",
    }, None, SPEECH)
    options = [option["text"] for operation in verdict["review_operations"]
               for option in operation["alternatives"]]
    assert len(options) == 2, "one question, not two"
    assert not any("восемь" in option for option in options), "w-sample wandered alone"


def test_a_reading_the_majority_corrects_is_applied_without_being_asked():
    # The primary transcript anchors the reference, so when it is the lone
    # dissenter the correction must still be carried — as the only option, which
    # the panel applies unattended rather than showing.
    verdict = decide({
        "w-greedy": "раз двое три альфа", "w-prompt": "раз два три альфа",
        "w-fallback": "раз два три альфа", "gigaam": "раз два три бета",
        "gigaam-ctc": "раз два три бета",
    }, None, SPEECH)
    settled = [operation for operation in verdict["review_operations"]
               if len(operation["alternatives"]) == 1]
    assert [operation["alternatives"][0]["text"] for operation in settled] == ["два"]
    assert len(verdict["review_operations"]) == 2, "альфа vs бета is still a real question"


def test_a_seven_way_split_keeps_its_question():
    # The most disputed spot there is: every decode reads it differently. The
    # operation must not vanish under pruning — but the lone Whisper readings
    # are still one model's noise, so what survives is the cross-architecture
    # evidence. The primary's own reading stays one click away in the panel
    # (it is the text being edited), not an option the vote has to re-offer.
    verdict = decide({name: f"раз {word} три" for name, word in
                      [("w-greedy", "а"), ("w-prompt", "б"), ("w-fallback", "в"),
                       ("gigaam", "г"), ("gigaam-ctc", "д")]}, None, SPEECH)
    assert verdict["review_operations"], "a full split must not be pruned away"
    alternatives = verdict["review_operations"][0]["alternatives"]
    assert [option["text"] for option in alternatives] == ["г", "д"]


def test_a_lone_gigaam_dissent_keeps_its_operation():
    # "whisper unanimous but gigaam dissents" used to lose EVERY operation: the
    # two-name floor counted six correlated Whisper decodes as six votes while
    # each dissenting GigaAM head counted as zero, so the file fell through to
    # a whole-transcript fallback card. A cross-architecture dissent is the one
    # lone reading that must survive the floor.
    verdict = decide({
        "w-greedy": "прошло еще час либо два", "w-prompt": "прошло еще час либо два",
        "w-fallback": "прошло еще час либо два", "w-sample": "прошло еще час либо два",
        "fw-beam": "прошло еще час либо два", "gigaam": "прошло еще час или два",
        "gigaam-ctc": "прошло еще час или два",
    }, None, SPEECH)
    assert verdict["status"] == "review"
    assert verdict["review_operations"], "the dissent must surface as an operation"
    texts = [option["text"] for option in verdict["review_operations"][0]["alternatives"]]
    assert "либо" in texts and "или" in texts, texts


def test_a_confirmed_term_removes_that_spot_everywhere():
    # The listener confirmed "ишью -> issue" against the audio once. From then
    # on it is one reading, not two, and the confirmed spelling is the one kept.
    candidates = {"w-greedy": "открой issue сейчас", "w-prompt": "открой issue сейчас",
                  "gigaam": "открой ишью сейчас", "gigaam-ctc": "открой ишью сейчас"}
    assert decide(candidates, None, SPEECH)["status"] == "review"
    settled = decide(candidates, {"ишью": ["issue"]}, SPEECH)
    assert settled["status"] == "accepted"
    assert settled["text"] == "открой issue сейчас"


def test_an_unconfirmed_cross_script_pair_is_still_a_question():
    # "аудио" against "audi" looks identical to a rule based on alphabet alone,
    # and folding it would bury a real mishearing under a spelling convention.
    verdict = decide({"w-greedy": "перевод audi в текст", "w-prompt": "перевод audi в текст",
                      "gigaam": "перевод аудио в текст", "gigaam-ctc": "перевод аудио в текст"},
                     None, SPEECH)
    assert verdict["status"] == "review"
    assert len(verdict["review_operations"][0]["alternatives"]) == 2


def test_number_notation_alone_is_not_an_operation():
    # canonical_numbers already stopped this counting as a disagreement in the
    # vote; the diff kept asking about it anyway, 115 times in the live queue.
    verdict = decide({"w-greedy": "жди 10 секунд и пиши", "w-prompt": "жди 10 секунд и пиши",
                      "gigaam": "жди десять секунд а пиши", "gigaam-ctc": "жди десять секунд а пиши"},
                     None, SPEECH)
    anchors = [operation["anchor"] for operation in verdict["review_operations"]]
    assert anchors == [[3, 4]], "only 'и' vs 'а' is left to decide"


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


def test_a_repeated_phrase_is_a_loop_too():
    # Only identical consecutive unigrams used to count, so "спасибо большое"
    # six times over was accepted at high confidence — the same hallucination
    # wearing two words instead of one.
    verdict = decide({"w-greedy": "спасибо большое " * 6, "gigaam": "спасибо большое " * 6},
                     None, {"no_speech": 0.3, "peak_db": -20.0})
    assert verdict["status"] == "review"


def test_a_short_genuine_repetition_is_not_a_loop():
    # "да да да" is something a person says; flagging it would push real
    # recordings into a queue that only works while it stays finishable.
    assert decide({"w-greedy": "да да да", "gigaam": "да да да"},
                  None, SPEECH)["status"] == "accepted"


def test_how_a_number_is_written_is_not_a_disagreement():
    # Whisper writes digits, GigaAM writes words. The engines agreed on the
    # number and differed only on notation in a third of the review queue.
    verdict = decide({"w-greedy": "последних 24 часа", "gigaam": "последних двадцать четыре часа"},
                     None, SPEECH)
    assert verdict["status"] == "accepted"


def test_a_different_number_still_is_one():
    # "5" against "6" is a question about what was said, and stays a question.
    assert decide({"w-greedy": "нужно 5 штук", "gigaam": "нужно 6 штук"},
                  None, SPEECH)["status"] == "review"


def test_separate_digits_are_not_summed_into_agreement():
    # Spelled numerals fold ("два три" -> 5) but digit tokens do not, so the
    # asymmetry can only miss a unification, never invent one.
    assert decide({"w-greedy": "возьми 2 3", "gigaam": "возьми два три"},
                  None, SPEECH)["status"] == "review"

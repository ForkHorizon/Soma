"""The harness decides whether a change shipped an improvement or a regression,
so the scoring itself must not be wrong. Everything here is pure — no audio, no
engine, no files on disk."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Scripts"))

from asr_eval import (  # noqa: E402
    contains,
    load_decodes,
    load_gold,
    paired_verdict,
    report,
    score,
    sign_test_p,
    spot_answers,
    spot_score,
)


def test_contains_matches_whole_words_not_letters():
    # "он" inside "она" is exactly the one-letter call the spot set measures;
    # a plain substring test would score it as a hit and hide the error.
    assert contains("он неправильно сделал", "он")
    assert not contains("она правильно сделала", "он")


def test_contains_matches_a_phrase_only_when_the_words_run_together():
    assert contains("я хочу чтобы ты посмотрел", "чтобы ты")
    assert not contains("я хочу чтобы посмотрел ты", "чтобы ты")


def test_contains_ignores_case_and_punctuation():
    # GigaAM writes unpunctuated lowercase, Whisper cased and punctuated.
    assert contains("Привет, ёжик!", "привет ежик")


def test_spot_score_credits_a_deletion_only_when_the_junk_is_gone():
    # The listener deleted a hallucinated caption; there is no chosen text to
    # look for, so the config is judged by the absence of what was thrown away.
    answer = {"file": "a.wav", "chosen": "", "rejected": ["Субтитры сделал DimaTorzok"]}
    assert spot_score("ну вот такая история", answer)
    assert not spot_score("ну вот такая история Субтитры сделал DimaTorzok", answer)


def test_spot_score_credits_a_correction_when_the_chosen_reading_is_present():
    answer = {"file": "a.wav", "chosen": "потенциальные", "rejected": ["потенциально"]}
    assert spot_score("мы обсудили потенциальные проблемы", answer)
    assert not spot_score("мы обсудили потенциально проблемы", answer)


VERDICTS = [
    {
        "file": "a.wav",
        "review_operations": [
            {"signature": "abc", "alternatives": [{"text": "пуш"}, {"text": "push"}]},
            {"signature": "def", "alternatives": [{"text": "Спасибо."}, {"text": ""}]},
        ],
    }
]


def test_spot_answers_recovers_what_each_decision_rejected():
    progress = [
        {"file": "a.wav", "signature": "abc", "text": "push"},
        {"file": "a.wav", "signature": "def", "text": ""},
    ]
    answers = spot_answers(VERDICTS, progress)
    assert [answer["chosen"] for answer in answers] == ["push", ""]
    assert answers[0]["rejected"] == ["пуш"]
    assert answers[1]["rejected"] == ["Спасибо."]


def test_spot_answers_drops_a_question_that_was_re_cut_since():
    # Re-running consensus renumbers operations. An answer whose signature no
    # longer exists cannot be scored, and must not be silently counted as a miss.
    assert spot_answers(VERDICTS, [{"file": "a.wav", "signature": "gone", "text": "x"}]) == []


def test_score_separates_a_config_that_ran_on_fewer_files():
    # w-offset only ever ran on the second tier. Its counts have to travel with
    # its rates, or a flattering WER drawn from a handful of files reads as a win.
    decodes = {"a.wav": {"full": "привет мир", "partial": "привет мир"}, "b.wav": {"full": "второй файл"}}
    results = score(decodes, {"a.wav": "привет мир", "b.wav": "второй файл"}, [])
    assert results["full"]["wer_n"] == 2 and results["full"]["wer"] == 0
    assert results["partial"]["wer_n"] == 1
    assert results["partial"]["files"] == 1


def test_score_reports_latin_and_punctuation_reach():
    # The two properties the anglicism and punctuation work is aimed at, so a
    # change that trades them away for WER cannot pass unnoticed.
    decodes = {"a.wav": {"eng": "сделай push,", "rus": "сделай пуш"}, "b.wav": {"eng": "готово", "rus": "готово"}}
    results = score(decodes, {}, [])
    assert results["eng"]["latin"] == 50.0 and results["eng"]["punct"] == 50.0
    assert results["rus"]["latin"] == 0.0 and results["rus"]["punct"] == 0.0


def test_score_keeps_per_file_wer_and_drift_for_paired_comparison():
    # 1.2: a mean over 94-99 gold files hides everything; the sign test needs
    # the per-file numbers a mean discards.
    decodes = {
        "a.wav": {"cfg": "привет мир", "gigaam": "привет мир"},
        "b.wav": {"cfg": "второй файл", "gigaam": "второй файл"},
    }
    results = score(decodes, {"a.wav": "привет мир", "b.wav": "второй файл"}, [])
    assert results["cfg"]["wer_by_file"] == {"a.wav": 0.0, "b.wav": 0.0}
    assert results["cfg"]["drift_by_file"] == {"a.wav": 0.0, "b.wav": 0.0}
    # gigaam is the drift anchor, not scored against itself
    assert results["gigaam"]["drift_by_file"] == {}


def test_sign_test_p_is_significant_for_a_lopsided_split_and_not_for_a_coin_flip():
    assert sign_test_p(31, 9) < 0.01


def test_sign_test_p_does_not_overflow_at_full_corpus_scale():
    # Regression: summing math.comb(n, i) into one Python int and then
    # multiplying by 0.5**n raised OverflowError once that int needed more
    # than a float's ~2**1024 range -- which a balanced split hits around
    # n=1024. Drift already scores the whole corpus (n~956) and only grows;
    # this must return a plain float, never raise, at any n, and a coin-flip
    # split must read as "not significant" rather than silently underflowing
    # to 0 (a first-draft fix of the overflow did exactly that at n=20000).
    assert sign_test_p(10000, 10000) == 1.0
    assert sign_test_p(100000, 100000) == 1.0
    assert 0.0 <= sign_test_p(9000, 11000) <= 1.0
    assert sign_test_p(199999, 1) == 0.0  # genuinely extreme skew: correctly ~0, doesn't crash
    assert sign_test_p(20, 20) == 1.0
    assert sign_test_p(0, 0) == 1.0


def test_paired_verdict_counts_wins_losses_and_excludes_ties_and_gaps():
    before = {"a.wav": 0.10, "b.wav": 0.20, "c.wav": 0.30, "d.wav": 0.05}
    now = {
        "a.wav": 0.05,  # win: dropped
        "b.wav": 0.20,  # tie: excluded
        "c.wav": 0.40,
    }  # loss: rose
    # d.wav only in "before" (e.g. new run dropped a file) — excluded, not a loss.
    line = paired_verdict("WER", now, before)
    assert line == "WER: wins 1 / losses 1 (n=2), p=1"


def test_paired_verdict_is_none_without_per_file_data_on_either_side():
    # Backward compatibility: a baseline saved before 1.2 has no *_by_file key.
    assert paired_verdict("WER", {"a.wav": 0.1}, None) is None
    assert paired_verdict("WER", None, {"a.wav": 0.1}) is None
    assert paired_verdict("WER", {}, {}) is None


def test_load_decodes_merges_multiple_files(tmp_path):
    # An experiment file never has gigaam (hygiene rule 1) -- it has to come
    # from a second, merged-in file for drift to be computable at all.
    experiment = tmp_path / "decodes-stage2.jsonl"
    experiment.write_text(
        '{"config": "w-p-p3-v1", "file": "a.wav", "text": "привет мир", "error": null}\n', encoding="utf-8"
    )
    main_cache = tmp_path / "decodes.jsonl"
    main_cache.write_text(
        '{"config": "gigaam", "file": "a.wav", "text": "привет мир", "error": null}\n', encoding="utf-8"
    )
    merged = load_decodes([experiment, main_cache])
    assert merged == {"a.wav": {"w-p-p3-v1": "привет мир", "gigaam": "привет мир"}}


def test_load_gold_excludes_consensus_rows_unless_explicitly_requested(tmp_path):
    path = tmp_path / "gold.jsonl"
    path.write_text(
        '{"file":"human.wav","text":"да","source":"review-session"}\n'
        '{"file":"auto.wav","text":"нет","source":"stage8-consensus"}\n',
        encoding="utf-8",
    )
    assert load_gold(path) == {"human.wav": "да"}
    assert load_gold(path, include_auto=True) == {"human.wav": "да", "auto.wav": "нет"}


def test_wer_uses_median_so_one_short_gold_reference_cant_swing_it():
    # issue #0088: same fragility as #0086, one file over. wer() is unbounded
    # above against a short gold reference, so a handful of short-reference
    # files pulled the mean WER to ~2x the median for nearly every real config.
    gold = {f"f{i}.wav": "привет мир" for i in range(5)}
    gold["outlier.wav"] = "да"
    decodes = {f"f{i}.wav": {"cfg": "привет мир"} for i in range(5)}
    decodes["outlier.wav"] = {"cfg": "а б в г д е ж з и к"}
    results = score(decodes, gold, [])
    assert results["cfg"]["wer"] == 0.0
    assert results["cfg"]["wer_by_file"]["outlier.wav"] > 2.0


def test_drift_uses_median_so_one_near_empty_gigaam_reference_cant_swing_it():
    # issue #0086: GigaAM occasionally decodes real speech as 1-2 words, and
    # wer() is unbounded above when the reference is that short -- a
    # hallucinating candidate can score >2.0 on that single file. A mean over
    # ~950 files let 3-4 such outliers swing the whole metric by +0.16;
    # median is untouched by a handful of files out of hundreds.
    decodes = {f"f{i}.wav": {"cfg": "привет мир", "gigaam": "привет мир"} for i in range(5)}
    decodes["outlier.wav"] = {"cfg": "а б в г д е ж з и к", "gigaam": "да"}
    results = score(decodes, {}, [])
    assert results["cfg"]["drift"] == 0.0
    assert results["cfg"]["drift_by_file"]["outlier.wav"] > 2.0  # the outlier is still recorded...
    # ...it just can't drag the aggregate with it the way a mean would (10/6 = 1.67 here).


def test_report_baseline_config_compares_every_result_against_one_fixed_reference(capsys):
    # Этап 2's actual need: does a brand-new config (never frozen under its
    # own name) beat w-greedy -- not "has w-greedy itself drifted".
    decodes = {
        "a.wav": {"w-p-p3-v1": "привет мир", "gigaam": "привет мир"},
        "b.wav": {"w-p-p3-v1": "второй файл", "gigaam": "второй файл"},
    }
    results = score(decodes, {"a.wav": "привет мир", "b.wav": "второй другой файл"}, [])
    baseline = {"w-greedy": {"wer": 0.5, "spots": 10.0, "drift": 0.5, "latin": 0.0, "punct": 0.0}}
    report(results, baseline, baseline_config="w-greedy")
    out = capsys.readouterr().out
    assert "better" in out or "WORSE" in out  # some delta line printed at all
    assert "w-p-p3-v1" in out


def test_report_without_baseline_config_falls_back_to_exact_name_match(capsys):
    # Backward compatibility: omitting --baseline-config keeps Этап 1's
    # before/after-the-same-config behavior unchanged.
    decodes = {"a.wav": {"w-greedy": "привет мир"}}
    results = score(decodes, {"a.wav": "привет мир"}, [])
    # baseline has no "w-greedy" entry with matching stats -> no reference found,
    # and definitely no accidental match against an unrelated config's stats.
    baseline = {"w-p-p3-v1": {"wer": 0.9, "spots": 1.0, "drift": 0.9, "latin": 0.0, "punct": 0.0}}
    report(results, baseline)
    out = capsys.readouterr().out
    assert "better" not in out and "WORSE" not in out

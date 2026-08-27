"""Stage 2.4: catching a prompt that poisons its own decodes, before an
overnight run is trusted. Everything here is pure -- no engine, no audio."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Scripts"))

from asr_prompt_leak import boilerplate_rates, check_leaks, leaks_prompt, load_rows  # noqa: E402


def test_leaks_prompt_catches_a_verbatim_run_not_said_in_this_file():
    prompt = "Диктовка по разработке: Swift, Xcode, Git, API."
    # "swift xcode git" is a 3-word run straight from the prompt; none of
    # those three words are anywhere in this file's actual gold text.
    assert leaks_prompt(prompt, "сегодня swift xcode git и ничего больше", "просто болтали ни о чем")


def test_leaks_prompt_does_not_flag_a_short_or_genuine_match():
    prompt = "Диктовка по разработке: Swift, Xcode, Git, API."
    # Only two words in a row overlap with the prompt -- below the run length.
    assert not leaks_prompt(prompt, "мы используем swift xcode для этого", "мы используем swift xcode для этого")
    # All three words genuinely were said (present in this file's own gold).
    assert not leaks_prompt(prompt, "мы пишем на swift xcode git сегодня", "мы пишем на swift xcode git сегодня")


def test_leaks_prompt_flags_even_if_one_of_the_three_words_is_coincidentally_true():
    # Deliberately sensitive: "и" is common enough it might appear in gold by
    # chance, but "swift xcode" together would not have -- this must still flag.
    prompt = "у нас Swift и Xcode"
    assert leaks_prompt(prompt, "сегодня у нас swift и xcode весь день", "у нас была встреча и обед")


def test_check_leaks_only_scores_files_present_in_gold():
    rows = {"a.wav": {"text": "swift xcode git собрание"}, "b.wav": {"text": "swift xcode git тоже"}}
    gold = {"a.wav": "было какое-то другое собрание"}  # b.wav has no gold row
    prompt = "Swift Xcode Git"
    assert check_leaks(rows, prompt, gold) == ["a.wav"]


def test_boilerplate_rates_reads_empty_low_confidence_and_looping_signals():
    rows = {
        "a.wav": {"text": "", "no_speech": 0.1},
        "b.wav": {"text": "спасибо", "no_speech": 0.9},
        "c.wav": {"text": "да да да да да да да", "no_speech": 0.1},
        "d.wav": {"text": "нормальный текст", "no_speech": 0.05},
    }
    rates = boilerplate_rates(rows)
    assert rates["n"] == 4
    assert rates["empty_rate"] == 25.0
    assert rates["low_confidence_rate"] == 25.0
    assert rates["looping_rate"] == 25.0


def test_boilerplate_rates_handles_no_rows_without_dividing_by_zero():
    rates = boilerplate_rates({})
    assert rates == {"n": 0, "empty_rate": None, "low_confidence_rate": None, "looping_rate": None}


def test_load_rows_skips_errors_and_other_configs(tmp_path):
    path = tmp_path / "decodes.jsonl"
    path.write_text(
        '{"config": "w-p-p3-v1", "file": "a.wav", "text": "ok", "error": null}\n'
        '{"config": "w-p-p3-v1", "file": "b.wav", "text": null, "error": "TimeoutError"}\n'
        '{"config": "w-greedy", "file": "a.wav", "text": "other config"}\n',
        encoding="utf-8",
    )
    rows = load_rows(path, "w-p-p3-v1")
    assert list(rows) == ["a.wav"]

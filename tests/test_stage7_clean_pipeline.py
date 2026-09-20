import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Scripts"))
from stage7_clean_pipeline import process  # noqa: E402


def test_credits_only_becomes_empty_with_all_safety_checks():
    rows = [{"file": "a.wav", "config": "w-greedy", "text": "Продолжение следует...", "error": None}]
    result = process(rows, {})
    assert result[0]["cleaned"] == ""
    assert result[0]["rules"] == ["strip_personal_credits"]
    assert all(result[0]["checks"].values())


def test_credits_tail_keeps_speech_and_numbers():
    rows = [{"file": "a.wav", "config": "w-greedy", "text": "У меня 42 файла. Продолжение следует...", "error": None}]
    result = process(rows, {})
    assert result[0]["cleaned"] == "У меня 42 файла."
    assert all(result[0]["checks"].values())


def test_keeps_non_target_configs_out_of_cleaned_artifact():
    rows = [{"file": "a.wav", "config": "gigaam", "text": "Продолжение следует...", "error": None}]
    assert process(rows, {}) == []


def test_glossary_spelling_survives_filter():
    rows = [{"file": "a.wav", "config": "w-greedy", "text": "Используй API. Продолжение следует...", "error": None}]
    result = process(rows, {"апи": ["api"]})
    assert result[0]["cleaned"] == "Используй API."
    assert result[0]["checks"]["glossary_terms_preserved"]


def test_subtitle_credits_are_cleaned_without_dropping_preceding_speech():
    rows = [{"file": "a.wav", "config": "w-greedy", "text": "Есть речь. Субтитры сделал DimaTorzok", "error": None}]
    result = process(rows, {})
    assert result[0]["cleaned"] == "Есть речь."

"""4.2's whole point is routing flips to the right bucket before a human ever
sees them: punctuation-only flips must never reach the listening sample (4.3
can't judge punctuation by ear), and the other three categories only need to
be roughly right, not exact -- they drive stratified sampling, not scoring."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Scripts"))

from flip_diff import classify, flips   # noqa: E402


def test_classify_punct_only_when_normalize_erases_the_difference():
    assert classify("привет, мир", "привет мир") == "punct"
    assert classify("Привет Мир", "привет мир") == "punct"


def test_classify_term_when_only_one_side_is_latin():
    assert classify("апи", "API") == "term"
    assert classify("используем Unity", "используем юнити") == "term"


def test_classify_filler_when_the_whole_diff_is_known_filler_words():
    assert classify("ну смотри", "смотри") == "filler"
    assert classify("это как бы работает", "это работает") == "filler"


def test_classify_phrasing_is_the_default():
    # A real wording change, not punctuation, not script, not a filler.
    assert classify("мы обсудили потенциальные проблемы", "мы обсудили потенциально проблемы") == "phrasing"


def test_flips_extracts_only_the_changed_span_not_the_whole_sentence():
    base = "привет как дела у тебя сегодня"
    candidate = "привет как дела у меня сегодня"
    found = flips(base, candidate, "cand", glossary=None)
    assert len(found) == 1
    assert found[0]["base"] == "тебя"
    assert found[0]["candidate"] == "меня"
    assert found[0]["category"] == "phrasing"


def test_flips_is_empty_when_the_texts_agree():
    assert flips("привет мир", "привет мир", "cand", glossary=None) == []


def test_flips_skips_a_pair_the_glossary_already_settled():
    # "ишью" -> "issue" confirmed by a human elsewhere in the project; review_
    # operations folds it before it ever reaches classify(), so it must not
    # show up as a phrasing/term flip here either.
    glossary = {"ишью": ["issue"]}
    assert flips("надо закрыть ишью", "надо закрыть issue", "cand", glossary) == []

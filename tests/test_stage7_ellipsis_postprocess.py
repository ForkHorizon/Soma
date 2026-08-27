import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Scripts"))
from stage7_ellipsis_postprocess import (
    compare,
    remove_planning_ellipsis,
    strip_continued_credits,
    strip_personal_credits,
)  # noqa: E402


def test_removes_terminal_planning_ellipsis():
    assert remove_planning_ellipsis("Сейчас я спрашиваю...") == "Сейчас я спрашиваю"


def test_removes_ellipsis_before_the_next_thought():
    assert remove_planning_ellipsis("очень резкая и... Не знаю") == "очень резкая и Не знаю"


def test_does_not_change_normal_punctuation():
    assert remove_planning_ellipsis("Вопрос? Да.") == "Вопрос? Да."


def test_audit_pair_is_explained_by_the_rule():
    assert compare("Подписка на...", "Подписка на")


def test_removes_standalone_continued_credits_to_empty():
    assert strip_continued_credits("Продолжение следует...") == ""


def test_removes_credits_tail_without_dropping_spoken_text():
    assert strip_continued_credits("Я закончил мысль. Продолжение следует...") == "Я закончил мысль."


def test_removes_subtitle_credit_with_or_without_name():
    assert strip_personal_credits("Субтитры сделал DimaTorzok") == ""
    assert strip_personal_credits("Реальная речь. Субтитры сделали") == "Реальная речь."

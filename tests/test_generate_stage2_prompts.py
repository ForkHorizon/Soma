"""Stage 2.1: the P2-P5 prompts must come from data, not from memory of what
sounds right. These tests are the check that the generator actually reads
glossary.json/gold.jsonl rather than a hardcoded list."""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Scripts"))

from generate_stage2_prompts import (  # noqa: E402
    build,
    glossary_terms,
    render_sentence,
    top_latin_terms,
)


def test_glossary_terms_dedupes_in_first_occurrence_order(tmp_path):
    (tmp_path / "glossary.json").write_text(
        json.dumps(
            {
                "пи": ["pr"],
                "пиэр": ["pr"],
                "ватсапу": ["whatsapp"],
                "юай": ["ui"],
            }
        ),
        encoding="utf-8",
    )
    assert glossary_terms(tmp_path) == ["pr", "whatsapp", "ui"]


def test_glossary_terms_is_empty_on_a_fresh_install_not_an_error(tmp_path):
    assert glossary_terms(tmp_path) == []


def test_top_latin_terms_ranks_by_frequency_then_alphabetically(tmp_path):
    (tmp_path / "gold.jsonl").write_text(
        '{"file": "a.wav", "text": "pr pr issue"}\n{"file": "b.wav", "text": "pr unity android"}\n', encoding="utf-8"
    )
    assert top_latin_terms(tmp_path, n=3) == ["pr", "android", "issue"]


def test_top_latin_terms_drops_single_character_tokenizer_artifacts(tmp_path):
    # "L-теаниль" normalizes (hyphen stripped) to two tokens: "l" and
    # "теаниль". The lone latin letter left over is not a technical term.
    (tmp_path / "gold.jsonl").write_text(
        '{"file": "a.wav", "text": "я пью таблетки L-теаниль каждый день"}\n', encoding="utf-8"
    )
    assert top_latin_terms(tmp_path) == []


def test_render_sentence_fills_in_display_case_and_leaves_others_alone():
    result = render_sentence("{pr} и {issue}", ["pr", "issue"])
    assert result == "PR и issue"


def test_render_sentence_refuses_a_term_set_the_template_does_not_cover():
    try:
        render_sentence("{pr} и {nonexistent}", ["pr", "issue"])
        assert False, "expected ValueError when the term set doesn't cover the template"
    except ValueError:
        pass


def test_build_skips_p2_when_glossary_is_empty_but_still_makes_p3_through_p5(tmp_path):
    (tmp_path / "gold.jsonl").write_text(
        "\n".join(
            json.dumps({"file": f"{i}.wav", "text": t})
            for i, t in enumerate(
                [
                    "pr issue sirena ui unity android developer email enum facetime",
                    "git hermes housedata input lines m1 mem nexus open project",
                ]
            )
        )
        + "\n",
        encoding="utf-8",
    )
    variants = build(tmp_path)
    assert "w-p-p2-v1" not in variants
    assert set(variants) == {"w-p-p3-v1", "w-p-p4-v1", "w-p-p5-v1"}
    for options in variants.values():
        assert options["temperature"] == 0.0
        assert options["initial_prompt"]

"""Stage 3: the decode-parameter grid (3.1 best_of, 3.2 filter thresholds)
must stay unique-named and optionally carry a stage-2 prompt without
duplicating it. Everything here is pure -- no engine, no audio."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Scripts"))

from generate_stage3_configs import (  # noqa: E402
    BEST_OF_GRID,
    JOINT_THRESHOLD_GRID,
    THRESHOLD_GRID,
    build,
    load_prompt,
)


def test_build_without_a_prompt_has_no_initial_prompt_key():
    variants = build(None)
    # +1 for w-turbo-v1 (3.4), which isn't part of either grid.
    assert len(variants) == len(BEST_OF_GRID) + len(THRESHOLD_GRID) + len(JOINT_THRESHOLD_GRID) + 1 == 13
    assert "w-turbo-v1" in variants
    assert all("initial_prompt" not in options for options in variants.values())


def test_build_with_a_prompt_bakes_it_into_every_variant():
    variants = build("Диктовка: Swift, Xcode.")
    assert all(options.get("initial_prompt") == "Диктовка: Swift, Xcode." for options in variants.values())


def test_build_names_are_all_unique_and_temperature_zero_for_thresholds():
    variants = build(None)
    assert len(variants) == len(set(variants))   # dict keys are already unique by construction,
                                                  # this documents the intent explicitly
    for param, value in THRESHOLD_GRID:
        matches = [name for name, options in variants.items()
                   if name.startswith("w-thr-") and options.get(param) == value]
        assert len(matches) == 1
        assert variants[matches[0]]["temperature"] == 0.0   # matches w-greedy's decode class


def test_build_includes_the_two_joint_threshold_followups():
    variants = build(None)
    for name, options in JOINT_THRESHOLD_GRID:
        assert variants[name] == {"temperature": 0.0, "condition_on_previous_text": False, **options}


def test_build_of_best_of_grid_covers_every_temperature_best_of_pair():
    variants = build(None)
    pairs = {(options["temperature"], options["best_of"])
             for options in variants.values() if "best_of" in options}
    assert pairs == set(BEST_OF_GRID)


def test_load_prompt_returns_none_without_a_name(tmp_path):
    assert load_prompt(None, tmp_path / "unused.json") is None


def test_load_prompt_reads_the_named_configs_initial_prompt(tmp_path):
    path = tmp_path / "prompts.json"
    path.write_text(json.dumps({"w-p-p5-v1": {"initial_prompt": "test prompt"}}), encoding="utf-8")
    assert load_prompt("w-p-p5-v1", path) == "test prompt"


def test_load_prompt_raises_on_an_unknown_name(tmp_path):
    path = tmp_path / "prompts.json"
    path.write_text(json.dumps({"w-p-p5-v1": {"initial_prompt": "x"}}), encoding="utf-8")
    try:
        load_prompt("w-p-typo-v1", path)
        assert False, "expected ValueError for a name not in the prompts file"
    except ValueError:
        pass

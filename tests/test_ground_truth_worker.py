"""1.3: the worker gained --out, --config-file and --beam-size for stage 2-3
experiments. Everything here is pure or mocked at the import boundary — no
real engine, no audio file, no network — so it runs without any venv."""

import json
import sys
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Scripts"))

import ground_truth_worker as worker  # noqa: E402


def test_load_config_file_returns_empty_dict_for_no_path():
    assert worker.load_config_file(None) == {}


def test_load_config_file_merges_additively_without_touching_built_ins(tmp_path):
    path = tmp_path / "exp.json"
    path.write_text(json.dumps({"w-p-glos-v1": {"temperature": 0.0, "initial_prompt": "Swift, Xcode"}}))
    custom = worker.load_config_file(path)
    merged = {**worker.WHISPER_OPTIONS, **custom}
    assert merged["w-p-glos-v1"]["initial_prompt"] == "Swift, Xcode"
    assert merged["w-greedy"] == worker.WHISPER_OPTIONS["w-greedy"]  # untouched
    assert "w-p-glos-v1" not in worker.WHISPER_OPTIONS  # module dict never mutated


def test_load_config_file_rejects_a_name_that_shadows_a_built_in(tmp_path):
    # The decode cache keys only on name+config (issue #0073): a config-file
    # entry silently reusing "w-greedy" with different options would poison
    # every future run reading that name from cache without ever raising.
    path = tmp_path / "exp.json"
    path.write_text(json.dumps({"w-greedy": {"temperature": 0.4}}))
    try:
        worker.load_config_file(path)
        assert False, "expected ValueError on a built-in name collision"
    except ValueError as error:
        assert "w-greedy" in str(error)


def test_build_decoder_forwards_beam_size_to_faster_whisper(monkeypatch):
    class FakeArgs:
        engine = "fasterwhisper"
        faster_model = "large-v3"
        faster_root = ""
        beam_size = 20

    captured = {}

    def fake_faster_whisper_decoder(model_size, root, beam_size):
        captured["beam_size"] = beam_size
        return lambda path: ("", {})

    monkeypatch.setattr(worker, "faster_whisper_decoder", fake_faster_whisper_decoder)
    worker.build_decoder(FakeArgs(), "fw-beam", {})
    assert captured["beam_size"] == 20


def test_whisper_decoder_builds_options_from_a_custom_config_without_touching_built_ins(monkeypatch):
    # import mlx_whisper is the first line of whisper_decoder(); fake it out so
    # this runs without the real (heavy, GPU-only) dependency installed.
    monkeypatch.setitem(sys.modules, "mlx_whisper", types.ModuleType("mlx_whisper"))
    options_map = {**worker.WHISPER_OPTIONS, "w-p-glos-v1": {"temperature": 0.0, "initial_prompt": "Swift, Xcode"}}
    decode = worker.whisper_decoder("w-p-glos-v1", "some/repo", 5, options_map)
    # `options` never leaves whisper_decoder except baked into decode()'s
    # closure -- recover it from there rather than reaching into mlx_whisper.
    built = dict(zip(decode.__code__.co_freevars, (cell.cell_contents for cell in decode.__closure__)))
    assert built["options"]["initial_prompt"] == "Swift, Xcode"
    assert built["options"]["path_or_hf_repo"] == "some/repo"
    assert built["options"]["word_timestamps"] is False  # only w-greedy gets word times
    assert worker.WHISPER_OPTIONS["w-greedy"] == {"temperature": 0.0, "condition_on_previous_text": False}


def test_main_writes_out_atomically_tmp_then_renamed(tmp_path):
    # Zero-file, zero-config run: exercises main()'s --out plumbing (open a
    # .tmp, close it, rename to the final path) without needing any engine.
    listing = tmp_path / "empty.txt"
    listing.write_text("")
    out_path = tmp_path / "decodes-smoke.jsonl"
    rc = worker.main(["--engine", "gigaam", "--configs", "", "--list", str(listing), "--out", str(out_path)])
    assert rc == 0
    assert out_path.exists()
    assert not out_path.with_suffix(out_path.suffix + ".tmp").exists()


def test_main_creates_outs_parent_directory_if_missing(tmp_path):
    # Regression: --out used to assume its parent already existed. The real
    # target (GroundTruth/experiments/) does not exist until the first
    # experiment ever writes to it -- the previous test's out_path lived
    # directly in tmp_path, which pytest already creates, so it never
    # exercised this.
    listing = tmp_path / "empty.txt"
    listing.write_text("")
    out_path = tmp_path / "experiments" / "decodes-stage2.jsonl"
    assert not out_path.parent.exists()
    rc = worker.main(["--engine", "gigaam", "--configs", "", "--list", str(listing), "--out", str(out_path)])
    assert rc == 0
    assert out_path.exists()


def test_main_without_out_does_not_write_any_file(tmp_path):
    # No --out given: worker must not silently create a decodes file next to
    # the recording list, only stdout.
    listing = tmp_path / "empty.txt"
    listing.write_text("")
    rc = worker.main(["--engine", "gigaam", "--configs", "", "--list", str(listing)])
    assert rc == 0
    assert list(tmp_path.iterdir()) == [listing]

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Scripts"))
from stage_c5_denoise_ab import FILTERS, DEV_PROMPT_P5, build_file_list  # noqa: E402


def test_filters_are_the_four_planned_candidates():
    assert FILTERS == ["dfn3", "rnnoise", "noisereduce", "fbdenoiser"]


def test_champion_prompt_matches_worker_dev_prompt():
    # P5 is the worker's DEV_PROMPT; C5 must decode with the exact champion config.
    import ground_truth_worker as worker
    assert worker.DEV_PROMPT == DEV_PROMPT_P5


def test_measurement_set_is_gold_plus_suspects_no_duplicates(tmp_path, monkeypatch):
    # Build a fake GT tree and verify set construction and dedupe.
    gt = tmp_path / "GroundTruth"
    (gt / "experiments").mkdir(parents=True)
    monkeypatch.setattr("stage_c5_denoise_ab.GT", gt)
    monkeypatch.setattr("stage_c5_denoise_ab.RECS", tmp_path / "VoiceRecordings")
    (tmp_path / "VoiceRecordings").mkdir()
    (gt / "gold.jsonl").write_text(json.dumps({"file": "rec-a.wav", "source": "human", "text": "x"}) + "\n"
                                   + json.dumps({"file": "rec-b.wav", "source": "human", "text": "y"}) + "\n")
    (gt / "experiments/cleaned-stage7-v1-w-greedy.jsonl").write_text(
        json.dumps({"file": "rec-b.wav", "verbatim": "v", "cleaned": "c"}) + "\n")  # b is suspect AND gold
    (gt / "experiments/empty-stage8.jsonl").write_text(json.dumps({"file": "rec-c.wav"}) + "\n")
    for name in ("rec-a.wav", "rec-b.wav", "rec-c.wav"):
        (tmp_path / "VoiceRecordings" / name).write_bytes(b"RIFF")
    files = build_file_list()
    assert sorted(Path(f).name for f in files) == ["rec-a.wav", "rec-b.wav", "rec-c.wav"]

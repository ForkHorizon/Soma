import json
import sys
from collections import Counter
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Scripts"))
import stage8_audit_sample as audit  # noqa: E402


def _rows():
    rows = []
    for tier, count in (("T1", 50), ("T2", 70)):
        for index in range(count):
            rows.append({"file": f"{tier}-{index}.wav", "text": f"text {index}",
                         "tier": tier, "confirmed_by": "parakeet,rnnt"})
    return rows


def test_build_sample_is_stratified_reproducible_and_interleaved(tmp_path):
    recordings = tmp_path / "recordings"
    recordings.mkdir()
    for row in _rows():
        (recordings / row["file"]).touch()
    first = audit.build_sample(_rows(), recordings, seed=7)
    second = audit.build_sample(_rows(), recordings, seed=7)
    assert first == second
    assert len(first) == 100
    assert Counter(row["tier"] for row in first) == {"T1": 40, "T2": 60}
    assert len({row["file"] for row in first}) == 100
    assert all(row["audio_exists"] for row in first)
    assert first[0]["tier"] == "T2" and first[1]["tier"] == "T1"
    assert all(row["audit_status"] == "pending" for row in first)


def test_main_refuses_manifest_when_selected_audio_is_missing(tmp_path):
    gt = tmp_path / "GroundTruth"
    exp = gt / "experiments"
    exp.mkdir(parents=True)
    (exp / "gold-stage8-auto.jsonl").write_text(
        "".join(json.dumps(row) + "\n" for row in _rows()), encoding="utf-8")
    recordings = tmp_path / "recordings"
    recordings.mkdir()
    with pytest.raises(RuntimeError, match="WAV"):
        audit.main(["--gt", str(gt), "--recordings", str(recordings), "--t1", "1", "--t2", "1"])

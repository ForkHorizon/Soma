import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Scripts"))

from migrate_ground_truth_storage import migrate  # noqa: E402


def test_migration_preserves_legacy_data_and_creates_empty_active_cycle(tmp_path):
    root = tmp_path / "GroundTruth"
    layer1 = tmp_path / "GroundTruthLayer1"
    (root / "Archive/legacy-gold-2026-08-26").mkdir(parents=True)
    (root / "experiments/stage7").mkdir(parents=True)
    layer1.mkdir()
    (root / "decodes.jsonl").write_text('{"file":"old.wav"}\n', encoding="utf-8")
    (root / "verdicts.jsonl").write_text('{"file":"old.wav","status":"review"}\n', encoding="utf-8")
    (root / "Archive/legacy-gold-2026-08-26/gold.jsonl").write_text(
        '{"file":"old.wav","source":"review-session","text":"старый"}\n', encoding="utf-8"
    )
    (root / "experiments/stage7/result.jsonl").write_text("old experiment\n", encoding="utf-8")
    (layer1 / "state.json").write_text('{"old":true}\n', encoding="utf-8")
    (layer1 / "model_commands.json").write_text('{"voice":{"command":"old"}}\n', encoding="utf-8")

    result = migrate(root, layer1, apply=True)

    assert result == {"moved": 6, "already_migrated": False}
    legacy = root / "archives/pre-structure-v1/root"
    assert (legacy / "gold.jsonl").read_text(encoding="utf-8") == (
        '{"file":"old.wav","source":"review-session","text":"старый"}\n'
    )
    assert (legacy / "decodes.jsonl").read_text(encoding="utf-8") == '{"file":"old.wav"}\n'
    assert (legacy / "experiments/stage7/result.jsonl").read_text(encoding="utf-8") == "old experiment\n"
    assert (root / "archives/pre-structure-v1/layer1/state.json").read_text(encoding="utf-8") == '{"old":true}\n'

    active = root / "active"
    assert json.loads((active / "manifest.json").read_text(encoding="utf-8"))["status"] == "not_started"
    assert (active / "human/gold.jsonl").read_text(encoding="utf-8") == ""
    assert (active / "evidence/decodes.jsonl").read_text(encoding="utf-8") == ""
    assert json.loads((active / "layer1/model_commands.json").read_text(encoding="utf-8")) == {
        "voice": {"command": "old"}
    }
    assert json.loads((active / "layer1/state.json").read_text(encoding="utf-8")) == {}

    second = migrate(root, layer1, apply=True)
    assert second == {"moved": 0, "already_migrated": True}


def test_migration_dry_run_does_not_move_files(tmp_path):
    root = tmp_path / "GroundTruth"
    layer1 = tmp_path / "GroundTruthLayer1"
    root.mkdir()
    layer1.mkdir()
    (root / "decodes.jsonl").write_text("legacy\n", encoding="utf-8")

    result = migrate(root, layer1, apply=False)

    assert result == {"moved": 2, "already_migrated": False}
    assert (root / "decodes.jsonl").read_text(encoding="utf-8") == "legacy\n"
    assert not (root / "active/manifest.json").exists()

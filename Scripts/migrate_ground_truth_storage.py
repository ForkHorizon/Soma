#!/usr/bin/env python3
"""Move pre-structure Soma Ground Truth data into an immutable archive.

The default invocation is a dry run. Use --apply only after reviewing the
listed moves. File contents are moved byte-for-byte; no JSONL is rewritten.
The operation is idempotent once active/manifest.json exists.
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path
from typing import Dict, Union

from ground_truth_paths import GROUND_TRUTH_ROOT

ROOT_FILENAMES = (
    "decodes.jsonl",
    "verdicts.jsonl",
    "review_progress.jsonl",
    "glossary.json",
    "verdicts.pre-vetov2-revote.jsonl",
)


def _move(source: Path, destination: Path, apply: bool) -> bool:
    if not source.exists():
        return False
    if destination.exists():
        raise FileExistsError(f"migration destination already exists: {destination}")
    print(f"move {source} -> {destination}")
    if apply:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(source), str(destination))
    return True


def migrate(root: Path, layer1_root: Path, apply: bool = False) -> Dict[str, Union[int, bool]]:
    """Plan or apply the migration for an arbitrary root, useful in tests."""
    root = root.expanduser()
    layer1_root = layer1_root.expanduser()
    active = root / "active"
    archive = root / "archives"
    snapshot = archive / "pre-structure-v1"
    legacy = snapshot / "root"
    active_layer1 = active / "layer1"
    active_layer2 = active / "layer2"
    manifest = active / "manifest.json"

    if manifest.exists():
        print(f"already migrated: {manifest}")
        return {"moved": 0, "already_migrated": True}
    if active.exists() and any(active.iterdir()):
        raise FileExistsError(f"active directory is not empty; refusing migration: {active}")

    moved = 0
    for filename in ROOT_FILENAMES:
        if _move(root / filename, legacy / filename, apply):
            moved += 1

    old_experiments = root / "experiments"
    if _move(old_experiments, legacy / "experiments", apply):
        moved += 1

    old_archive = root / "Archive"
    if old_archive.exists():
        old_gold = next(old_archive.rglob("gold.jsonl"), None)
        if old_gold is not None and not (legacy / "gold.jsonl").exists():
            if _move(old_gold, legacy / "gold.jsonl", apply):
                moved += 1
        remaining_archive = snapshot / "legacy-archive"
        for child in sorted(old_archive.iterdir()):
            if old_gold is not None and child == old_gold:
                continue
            if _move(child, remaining_archive / child.name, apply):
                moved += 1
        if apply and old_archive.exists() and not any(old_archive.iterdir()):
            old_archive.rmdir()

    if _move(layer1_root, snapshot / "layer1", apply):
        moved += 1

    if apply:
        _create_active_cycle(active, active_layer1, active_layer2, snapshot, manifest)

    return {"moved": moved, "already_migrated": False}


def _create_active_cycle(
    active: Path, active_layer1: Path, active_layer2: Path, snapshot: Path, manifest: Path
) -> None:
    for directory in (
        active / "human",
        active / "evidence",
        active / "experiments" / "stage7",
        active / "experiments" / "stage8",
        active / "experiments" / "other",
        active_layer1 / "batch-manifests",
        active_layer2,
    ):
        directory.mkdir(parents=True, exist_ok=True)
    for path in (
        active / "human" / "gold.jsonl",
        active / "human" / "review_progress.jsonl",
        active / "evidence" / "decodes.jsonl",
        active / "evidence" / "verdicts.jsonl",
        active_layer1 / "history.jsonl",
        active_layer2 / "preferred.jsonl",
    ):
        path.touch()
    (active / "human" / "glossary.json").write_text("{}\n", encoding="utf-8")
    archived_commands = snapshot / "layer1" / "model_commands.json"
    if archived_commands.exists():
        shutil.copy2(archived_commands, active_layer1 / "model_commands.json")
    else:
        (active_layer1 / "model_commands.json").write_text("{}\n", encoding="utf-8")
    (active_layer1 / "state.json").write_text("{}\n", encoding="utf-8")
    active.mkdir(parents=True, exist_ok=True)
    manifest.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "cycle_id": "layer1-v1",
                "status": "not_started",
                "gold_policy": "human_verified_only",
                "active_root": str(active),
                "legacy_snapshot": str(snapshot),
            },
            indent=2,
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"created active cycle: {active}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=GROUND_TRUTH_ROOT)
    parser.add_argument(
        "--layer1-root", type=Path, default=Path.home() / "Library/Application Support/Soma/GroundTruthLayer1"
    )
    parser.add_argument("--apply", action="store_true", help="apply the migration; default is dry-run")
    args = parser.parse_args(argv)
    migrate(args.root, args.layer1_root, apply=args.apply)
    if not args.apply:
        print("dry-run only; rerun with --apply to move files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

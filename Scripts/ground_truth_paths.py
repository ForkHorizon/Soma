"""Canonical filesystem contract for Soma's ground-truth stores.

The active cycle is intentionally separate from archived historical material.
Scripts for the old Stage-5/7/8 pipeline use LEGACY_ROOT by default; new
Layer-1 work uses ACTIVE_ROOT and ACTIVE_LAYER1_ROOT.
"""

from pathlib import Path

GROUND_TRUTH_ROOT = Path.home() / "Library/Application Support/Soma/GroundTruth"
ACTIVE_ROOT = GROUND_TRUTH_ROOT / "active"
ACTIVE_HUMAN_ROOT = ACTIVE_ROOT / "human"
ACTIVE_EVIDENCE_ROOT = ACTIVE_ROOT / "evidence"
ACTIVE_EXPERIMENTS_ROOT = ACTIVE_ROOT / "experiments"
ACTIVE_LAYER1_ROOT = ACTIVE_ROOT / "layer1"

ARCHIVE_ROOT = GROUND_TRUTH_ROOT / "archives"
MIGRATION_SNAPSHOT_ROOT = ARCHIVE_ROOT / "pre-structure-v1"
LEGACY_ROOT = MIGRATION_SNAPSHOT_ROOT / "root"
LEGACY_EXPERIMENTS_ROOT = LEGACY_ROOT / "experiments"
LEGACY_LAYER1_ROOT = MIGRATION_SNAPSHOT_ROOT / "layer1"

ACTIVE_GOLD = ACTIVE_HUMAN_ROOT / "gold.jsonl"
ACTIVE_REVIEW_PROGRESS = ACTIVE_HUMAN_ROOT / "review_progress.jsonl"
ACTIVE_GLOSSARY = ACTIVE_HUMAN_ROOT / "glossary.json"
ACTIVE_DECODES = ACTIVE_EVIDENCE_ROOT / "decodes.jsonl"
ACTIVE_VERDICTS = ACTIVE_EVIDENCE_ROOT / "verdicts.jsonl"
ACTIVE_LAYER1_STATE = ACTIVE_LAYER1_ROOT / "state.json"
ACTIVE_LAYER1_HISTORY = ACTIVE_LAYER1_ROOT / "history.jsonl"
ACTIVE_LAYER1_COMMANDS = ACTIVE_LAYER1_ROOT / "model_commands.json"
ACTIVE_MANIFEST = ACTIVE_ROOT / "manifest.json"


def active_experiment(name: str) -> Path:
    """Return a path under the active derived-artifact namespace."""
    return ACTIVE_EXPERIMENTS_ROOT / name


def legacy_experiment(name: str) -> Path:
    """Return a path under the archived historical experiment namespace."""
    return LEGACY_EXPERIMENTS_ROOT / name

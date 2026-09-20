#!/usr/bin/env python3
"""Create a reproducible human-audit sample from Stage-8 auto-gold.

The output is deliberately separate from the real GroundTruth stores. Each
row contains the proposed transcript and the absolute WAV path, plus blank
fields for a human listener's verdict. It is an audit artifact, not gold.
"""

from __future__ import annotations

import argparse
import json
import random
from itertools import zip_longest
from pathlib import Path

from ground_truth_paths import LEGACY_ROOT

DEFAULT_GT = LEGACY_ROOT
DEFAULT_RECORDINGS = Path.home() / "Library/Application Support/Soma/VoiceRecordings"
DEFAULT_SEED = 20260822


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def interleave(t1: list[dict], t2: list[dict]) -> list[dict]:
    """Interleave risk tiers, starting with T2, so a partial audit stays mixed."""
    rows = []
    for higher_risk, lower_risk in zip_longest(t2, t1):
        if higher_risk is not None:
            rows.append(higher_risk)
        if lower_risk is not None:
            rows.append(lower_risk)
    return rows


def build_sample(rows: list[dict], recordings: Path, seed: int, t1_count: int = 40, t2_count: int = 60) -> list[dict]:
    by_tier = {tier: [row for row in rows if row.get("tier") == tier] for tier in ("T1", "T2")}
    if len(by_tier["T1"]) < t1_count or len(by_tier["T2"]) < t2_count:
        raise ValueError(f"Need T1={t1_count}, T2={t2_count}; found T1={len(by_tier['T1'])}, T2={len(by_tier['T2'])}")
    rng = random.Random(seed)
    t1 = rng.sample(by_tier["T1"], t1_count)
    t2 = rng.sample(by_tier["T2"], t2_count)
    sample = []
    for index, row in enumerate(interleave(t1, t2), start=1):
        audio = recordings / row["file"]
        sample.append(
            {
                "sample_id": index,
                "file": row["file"],
                "audio_path": str(audio),
                "audio_exists": audio.is_file(),
                "proposed_text": row["text"],
                "tier": row["tier"],
                "confirmed_by": row["confirmed_by"],
                "audit_status": "pending",
                "audited_text": None,
                "notes": None,
            }
        )
    return sample


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gt", type=Path, default=DEFAULT_GT)
    parser.add_argument("--recordings", type=Path, default=DEFAULT_RECORDINGS)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--t1", type=int, default=40)
    parser.add_argument("--t2", type=int, default=60)
    parser.add_argument("--out", type=Path)
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse(argv)
    source = args.gt / "experiments/gold-stage8-auto.jsonl"
    out = args.out or args.gt / "experiments/stage8-auto-audit-100.jsonl"
    sample = build_sample(read_jsonl(source), args.recordings, args.seed, args.t1, args.t2)
    missing = [row["file"] for row in sample if not row["audio_exists"]]
    if missing:
        raise RuntimeError(f"Refusing to emit an unusable audit: {len(missing)} WAV(s) missing")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in sample), encoding="utf-8")
    print(f"wrote {len(sample)} rows: T1={args.t1}, T2={args.t2}, seed={args.seed}")
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

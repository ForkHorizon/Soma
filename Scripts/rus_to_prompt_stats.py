#!/usr/bin/env python3
"""Aggregate Rus to Prompt model quality across saved stress-test logs."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from rus_to_prompt_stats_aggregate import aggregate_stats
from rus_to_prompt_stats_core import provider_for_model


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stress-dir", default=str(ROOT / ".stress"))
    parser.add_argument("--pretty", action="store_true")
    args = parser.parse_args()

    payload = aggregate_stats(Path(args.stress_dir))
    print(json.dumps(payload, ensure_ascii=False, indent=2 if args.pretty else None))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

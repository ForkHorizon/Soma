#!/usr/bin/env python3
"""Summarize guarded Stage-7 v2 local-LLM A/B results."""
import json
from collections import Counter
from pathlib import Path

GT = Path.home() / "Library/Application Support/Soma/GroundTruth"


def main():
    p = GT / "experiments/stage7-v2-qwen3-14b-v1base-audit.jsonl"
    rows = [json.loads(x) for x in p.read_text().splitlines() if x]
    total, match, accepted = Counter(), Counter(), Counter()
    for row in rows:
        label = row["label"]
        total[label] += 1
        accepted[label] += bool(row["accepted"])
        matched = (not row["candidate"].strip() and row["human_cleaned"].strip() in ("", ".")) \
            if label == "no_speech" else row["candidate"] == row["human_cleaned"]
        if matched:
            match[label] += 1
    report = {label: {"total": total[label], "guard_accepted": accepted[label], "exact_human": match[label]}
              for label in sorted(total)}
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

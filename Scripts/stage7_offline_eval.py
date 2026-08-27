#!/usr/bin/env python3
"""Offline A/B evaluator for the human Stage-7 punctuation audit."""

import json
from collections import Counter
from pathlib import Path

GT = Path.home() / "Library/Application Support/Soma/GroundTruth"


def matches(label, candidate, human):
    if label == "no_speech":
        # The initial audit UI could not save an empty correction, so a lone
        # period is the listener's recorded sentinel for silence.
        return not candidate.strip() and human.strip() in ("", ".")
    return candidate == human


def main():
    exp = GT / "experiments"
    human = [json.loads(x) for x in (exp / "stage7-punctuation-eval-60.jsonl").read_text().splitlines() if x]
    candidate = {
        r["file"]: r["cleaned"]
        for r in map(json.loads, (exp / "cleaned-stage7-v1-w-greedy.jsonl").read_text().splitlines())
    }
    totals, hits = Counter(), Counter()
    for row in human:
        totals[row["label"]] += 1
        if matches(row["label"], candidate[row["file"]], row["human_cleaned"]):
            hits[row["label"]] += 1
    report = {
        "total": sum(totals.values()),
        "matched": sum(hits.values()),
        "by_label": {label: {"matched": hits[label], "total": totals[label]} for label in sorted(totals)},
    }
    out = exp / "stage7-v1-offline-ab.json"
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()

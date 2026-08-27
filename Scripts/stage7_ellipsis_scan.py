#!/usr/bin/env python3
"""Scan existing decode artifacts for the experimental Stage-7 ellipsis rule.

Read-only: this produces a report only and never changes decodes, gold, or UI.
"""

import argparse
import json
from collections import Counter
from pathlib import Path

from stage7_ellipsis_postprocess import remove_planning_ellipsis

DEFAULT_GT = Path.home() / "Library/Application Support/Soma/GroundTruth"


def read_rows(path):
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def scan(paths, examples=20):
    total = changed = 0
    by_config = Counter()
    sample = []
    for path in paths:
        for row in read_rows(path):
            if row.get("error") or not row.get("file") or "text" not in row:
                continue
            total += 1
            before = row.get("text") or ""
            after = remove_planning_ellipsis(before)
            if before == after:
                continue
            changed += 1
            config = row.get("config", path.stem)
            by_config[config] += 1
            if len(sample) < examples:
                sample.append(
                    {"file": row["file"], "config": config, "before": before, "after": after, "artifact": path.name}
                )
    return {
        "rows_scanned": total,
        "rows_changed": changed,
        "by_config": dict(sorted(by_config.items())),
        "examples": sample,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gt", type=Path, default=DEFAULT_GT)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--examples", type=int, default=20)
    args = parser.parse_args(argv)
    exp = args.gt / "experiments"
    paths = [args.gt / "decodes.jsonl", *sorted(exp.glob("decodes-stage8-*.jsonl"))]
    paths = [path for path in paths if path.exists()]
    report = scan(paths, args.examples)
    report["artifacts"] = [path.name for path in paths]
    out = args.out or exp / "stage7-ellipsis-scan.json"
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"scanned {report['rows_scanned']} decode rows; rule changes {report['rows_changed']}")
    print(out)


if __name__ == "__main__":
    main()

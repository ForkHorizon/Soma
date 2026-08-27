#!/usr/bin/env python3
"""Build the non-destructive Stage-8 expanded corpus.

Combines the existing gold with audited Stage-8 consensus rows without changing
main gold.jsonl. Provenance is retained on every row so engine evaluation can
exclude consensus-derived references.
"""
import argparse
import json
from pathlib import Path

DEFAULT_GT = Path.home() / "Library/Application Support/Soma/GroundTruth"


def rows(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def build(main, auto):
    merged = {row["file"]: row for row in main}
    for row in auto:
        if row["file"] in merged:
            raise ValueError(f"duplicate gold file: {row['file']}")
        merged[row["file"]] = row
    return [merged[file] for file in sorted(merged)]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gt", type=Path, default=DEFAULT_GT)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args(argv)
    out = args.out or args.gt / "experiments/gold-stage8-expanded.jsonl"
    result = build(rows(args.gt / "gold.jsonl"), rows(args.gt / "experiments/gold-stage8-auto.jsonl"))
    out.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in result), encoding="utf-8")
    print(f"wrote {len(result)} rows -> {out}")


if __name__ == "__main__":
    main()

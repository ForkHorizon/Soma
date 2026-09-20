#!/usr/bin/env python3
"""Materialize Stage-7 human punctuation decisions as an evaluation dataset."""

import json
from pathlib import Path

from ground_truth_paths import LEGACY_ROOT
from stage7_ellipsis_postprocess import strip_personal_credits

GT = LEGACY_ROOT


def main():
    exp = GT / "experiments"
    manifest = {
        r["sample_id"]: r for r in map(json.loads, (exp / "stage7-ellipsis-audit-60.jsonl").read_text().splitlines())
    }
    latest = {}
    for line in (exp / "stage7-ellipsis-audit-decisions.jsonl").read_text().splitlines():
        if line:
            row = json.loads(line)
            latest[row["sample_id"]] = row
    output = []
    for sample_id, decision in sorted(latest.items()):
        sample = manifest[sample_id]
        before, after = sample["proposed_text"], decision["audited_text"]
        filtered = strip_personal_credits(before)
        if after == before:
            label = "keep"
        elif not filtered and after in ("", "."):
            label = "no_speech"
        elif filtered != before and after == filtered:
            label = "strip_personal_credits"
        else:
            label = "punctuation_edit"
        output.append(
            {
                "file": sample["file"],
                "tier": sample["tier"],
                "verbatim": before,
                "human_cleaned": after,
                "label": label,
                "audit_status": decision["status"],
            }
        )
    out = exp / "stage7-punctuation-eval-60.jsonl"
    out.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in output), encoding="utf-8")
    print(f"wrote {len(output)} rows -> {out}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Create a 30 terminal / 30 inline ellipsis listening sample from w-greedy."""

import json
import random
import re
from pathlib import Path

GT = Path.home() / "Library/Application Support/Soma/GroundTruth"
RECORDINGS = Path.home() / "Library/Application Support/Soma/VoiceRecordings"
ELLIPSIS = re.compile(r"\.\.\.")


def main():
    buckets = {"terminal": [], "inline": []}
    for line in (GT / "decodes.jsonl").read_text(encoding="utf-8").splitlines():
        row = json.loads(line)
        text = row.get("text") or ""
        if row.get("config") != "w-greedy" or row.get("error") or "..." not in text:
            continue
        kind = "inline" if any(text[m.end() :].strip() for m in ELLIPSIS.finditer(text)) else "terminal"
        buckets[kind].append(row)
    rng = random.Random(20260823)
    # Preserve the production config. It has only 27 inline cases, so audit all
    # of them and fill the fixed 60-clip budget with terminal cases.
    inline_count = min(30, len(buckets["inline"]))
    terminal_count = 60 - inline_count
    if len(buckets["terminal"]) < terminal_count:
        raise RuntimeError("not enough terminal ellipsis cases")
    selected = {
        "inline": rng.sample(buckets["inline"], inline_count),
        "terminal": rng.sample(buckets["terminal"], terminal_count),
    }
    output = []
    output = selected["inline"] + selected["terminal"]
    rows = []
    for index, row in enumerate(output, 1):
        text = row["text"]
        kind = "inline" if any(text[m.end() :].strip() for m in ELLIPSIS.finditer(text)) else "terminal"
        audio = RECORDINGS / row["file"]
        if not audio.is_file():
            raise RuntimeError(f"missing audio: {audio}")
        rows.append(
            {
                "sample_id": index,
                "file": row["file"],
                "audio_path": str(audio),
                "audio_exists": True,
                "proposed_text": text,
                "tier": kind,
                "confirmed_by": "w-greedy",
                "audit_status": "pending",
                "audited_text": None,
                "notes": None,
            }
        )
    out = GT / "experiments/stage7-ellipsis-audit-60.jsonl"
    out.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows), encoding="utf-8")
    print(f"wrote {len(rows)} rows; selected terminal={terminal_count}, inline={inline_count}")
    print(out)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""4.2: extract only the regions where a candidate decode actually differs from
the base, classified so 4.3's listening sample can skip what a human doesn't
need to judge by ear.

Alignment is not reimplemented here -- `ground_truth_consensus.review_operations`
already does exactly this (diff two-or-more transcripts, keep only the changed
spans, anchor them to word positions in the base transcript) for the human
review panel. Two decodes is the degenerate case of the same machinery: base
plays the role of the primary transcript, the candidate is the sole "other"
config, and every operation it returns has exactly one alternative from each
side (settled-equivalent spans -- glossary-confirmed pairs, spelled-out numbers
-- are already folded together and never appear as an operation at all).

    ./flip_diff.py --base-decodes ~/.../decodes.jsonl --base-config w-greedy \\
        --candidate-decodes ~/.../decodes-stage3-bo10.jsonl --candidate-config w-bo-t20-n10-v1 \\
        --out experiments/flips-final-candidate.jsonl
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from asr_eval import load_decodes  # noqa: E402
from ground_truth_consensus import PRIMARY, review_operations  # noqa: E402
from ground_truth_text import normalize  # noqa: E402

DEFAULT_ROOT = Path.home() / "Library/Application Support/Soma/GroundTruth"
_LATIN = re.compile(r"[a-zA-Z]")

# Deliberately short and explicit rather than derived: a false "filler" match
# just puts a real wording change in the wrong stratification bucket, it
# doesn't corrupt the transcript, so there is nothing here worth being clever
# about. Extend by hand if 4.3's sample turns up an obvious miss.
FILLERS = {"ну", "вот", "как бы", "типа", "короче", "это", "в общем", "то есть", "значит", "получается", "собственно"}


def load_glossary(root: Path) -> dict[str, list[str]]:
    path = root / "glossary.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}


def _without_fillers(text: str) -> str:
    """Strip each known filler PHRASE (not word) so multi-word entries like
    "как бы" match as a unit -- a plain word-set diff would instead see the
    unrelated tokens "как" and "бы" and miss the phrase entirely."""
    for filler in FILLERS:
        text = re.sub(rf"(?:^|(?<=\s)){re.escape(filler)}(?:(?=\s)|$)", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def classify(base: str, candidate: str) -> str:
    """punct / term / filler / phrasing, checked in that priority order -- a
    flip can plausibly match more than one description, and 4.3 only needs one
    bucket per flip, not a full taxonomy."""
    if normalize(base) == normalize(candidate):
        return "punct"
    if bool(_LATIN.search(base)) != bool(_LATIN.search(candidate)):
        return "term"
    if _without_fillers(normalize(base)) == _without_fillers(normalize(candidate)):
        return "filler"
    return "phrasing"


def flips(
    base_text: str, candidate_text: str, candidate_name: str, glossary: dict[str, list[str]] | None
) -> list[dict]:
    operations = review_operations({PRIMARY: base_text, candidate_name: candidate_text}, glossary)
    found = []
    for operation in operations:
        by_name = {name: option["text"] for option in operation["alternatives"] for name in option["names"]}
        base, candidate = by_name.get(PRIMARY), by_name.get(candidate_name)
        if base is None or candidate is None:
            continue  # settled-equivalent or one-sided -- review_operations already decided this isn't a flip
        found.append(
            {
                "anchor": operation["anchor"],
                "context_before": operation["context"][0],
                "context_after": operation["context"][1],
                "base": base,
                "candidate": candidate,
                "category": classify(base, candidate),
            }
        )
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--base-decodes", type=Path, action="append", required=True)
    parser.add_argument("--base-config", default=PRIMARY)
    parser.add_argument("--candidate-decodes", type=Path, action="append", required=True)
    parser.add_argument("--candidate-config", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    base_decodes = load_decodes(args.base_decodes)
    candidate_decodes = load_decodes(args.candidate_decodes)
    files = sorted(set(base_decodes) & set(candidate_decodes))
    glossary = load_glossary(args.root)

    rows = []
    counts = {"punct": 0, "term": 0, "filler": 0, "phrasing": 0}
    for file in files:
        base_text = base_decodes[file].get(args.base_config)
        candidate_text = candidate_decodes[file].get(args.candidate_config)
        if base_text is None or candidate_text is None:
            continue
        for flip in flips(base_text, candidate_text, args.candidate_config, glossary):
            counts[flip["category"]] += 1
            rows.append({"file": file, **flip})

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows), encoding="utf-8")
    listenable = counts["term"] + counts["filler"] + counts["phrasing"]
    print(
        f"{len(rows)} flips across {len(files)} shared files: "
        f"punct/case {counts['punct']} (excluded from 4.3's sample) | "
        f"term {counts['term']} | filler {counts['filler']} | phrasing {counts['phrasing']} "
        f"-> {listenable} listenable"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

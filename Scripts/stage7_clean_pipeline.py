#!/usr/bin/env python3
"""Produce a reversible Stage-7 cleaned transcript artifact from cached decodes.

The verbatim decode is immutable. This pipeline writes a separate JSONL with a
cleaned projection and refuses transformations that add words, alter numbers,
or remove configured glossary spellings.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

from ground_truth_text import normalize
from stage7_ellipsis_postprocess import strip_personal_credits

DEFAULT_GT = Path.home() / "Library/Application Support/Soma/GroundTruth"
NUMBER = re.compile(r"\d+(?:[.,]\d+)?")


def is_subsequence(after: list[str], before: list[str]) -> bool:
    cursor = iter(before)
    return all(any(word == candidate for candidate in cursor) for word in after)


def preserved_glossary_terms(before: str, after: str, glossary: dict[str, list[str]]) -> bool:
    before_norm, after_norm = normalize(before), normalize(after)
    spellings = {normalize(item) for values in glossary.values() for item in values if normalize(item)}
    return all(term not in before_norm or term in after_norm for term in spellings)


def clean(text: str) -> tuple[str, list[str]]:
    result = strip_personal_credits(text)
    return result, (["strip_personal_credits"] if result != text else [])


def process(rows, glossary):
    output = []
    for row in rows:
        if row.get("error") or row.get("config") != "w-greedy" or not row.get("file"):
            continue
        verbatim = row.get("text") or ""
        cleaned, rules = clean(verbatim)
        checks = {
            "no_added_words": is_subsequence(normalize(cleaned).split(), normalize(verbatim).split()),
            "numbers_unchanged": NUMBER.findall(cleaned) == NUMBER.findall(verbatim),
            "glossary_terms_preserved": preserved_glossary_terms(verbatim, cleaned, glossary),
        }
        if not all(checks.values()):
            raise ValueError(f"unsafe Stage-7 transformation for {row['file']}: {checks}")
        output.append({"file": row["file"], "config": row["config"], "verbatim": verbatim,
                       "cleaned": cleaned, "rules": rules, "checks": checks})
    return output


def load_jsonl(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gt", type=Path, default=DEFAULT_GT)
    parser.add_argument("--input", type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args(argv)
    source = args.input or args.gt / "decodes.jsonl"
    glossary_path = args.gt / "glossary.json"
    glossary = json.loads(glossary_path.read_text(encoding="utf-8")) if glossary_path.exists() else {}
    result = process(load_jsonl(source), glossary)
    out = args.out or args.gt / "experiments/cleaned-stage7-v1-w-greedy.jsonl"
    out.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in result), encoding="utf-8")
    changed = sum(bool(row["rules"]) for row in result)
    print(f"wrote {len(result)} rows; {changed} changed -> {out}")


if __name__ == "__main__":
    main()

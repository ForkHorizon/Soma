#!/usr/bin/env python3
"""Run a guarded local-LLM punctuation A/B on the Stage-7 human audit."""

import json
import urllib.request
import argparse
from pathlib import Path

from ground_truth_paths import LEGACY_ROOT
from ground_truth_text import normalize
from stage7_clean_pipeline import NUMBER, is_subsequence, preserved_glossary_terms
from stage7_ellipsis_postprocess import strip_personal_credits

GT = LEGACY_ROOT
MODEL = "qwen3:14b"
PROMPT = """Ты редактор пунктуации русского ASR. Верни ТОЛЬКО исходный текст с исправленными запятыми, точками, заглавными буквами и троеточиями. Нельзя добавлять, удалять, заменять или переставлять слова, числа и термины. Если не уверен — оставь пунктуацию как есть. Без пояснений.\n\nТекст:\n"""


def generate(text):
    request = urllib.request.Request(
        "http://127.0.0.1:11434/api/generate",
        data=json.dumps(
            {
                "model": MODEL,
                "prompt": PROMPT + text,
                "stream": False,
                "options": {"temperature": 0, "num_ctx": 4096, "num_predict": 1024},
            }
        ).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        return json.loads(response.read())["response"].strip()


def safe(before, after, glossary):
    return (
        is_subsequence(normalize(after).split(), normalize(before).split())
        and NUMBER.findall(after) == NUMBER.findall(before)
        and preserved_glossary_terms(before, after, glossary)
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()
    exp = GT / "experiments"
    glossary = json.loads((GT / "glossary.json").read_text())
    rows = [json.loads(x) for x in (exp / "stage7-punctuation-eval-60.jsonl").read_text().splitlines() if x]
    if args.limit:
        rows = rows[: args.limit]
    out = exp / "stage7-v2-qwen3-14b-v1base-audit.jsonl"
    done = {json.loads(x)["file"] for x in out.read_text().splitlines() if x} if out.exists() else set()
    with out.open("a", encoding="utf-8") as handle:
        for index, row in enumerate(rows, 1):
            if row["file"] in done:
                continue
            baseline = strip_personal_credits(row["verbatim"])
            raw = generate(baseline) if baseline else ""
            accepted = True if not baseline else safe(baseline, raw, glossary)
            candidate = raw if accepted else baseline
            handle.write(
                json.dumps(
                    {
                        "file": row["file"],
                        "label": row["label"],
                        "verbatim": row["verbatim"],
                        "human_cleaned": row["human_cleaned"],
                        "baseline": baseline,
                        "candidate": candidate,
                        "raw": raw,
                        "accepted": accepted,
                    },
                    ensure_ascii=False,
                )
                + "\n"
            )
            handle.flush()
            print(f"{index}/{len(rows)} accepted={accepted}", flush=True)


if __name__ == "__main__":
    main()

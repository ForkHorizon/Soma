#!/usr/bin/env python3
"""Stage 2.1: generate the P2-P5 initial_prompt variants from data, not from
memory of what "sounds right" — the plan is explicit that these come from
glossary.json / gold.jsonl, never invented.

P0 and P1 are not here: they already exist as the built-in w-greedy (empty
prompt) and w-prompt (DEV_PROMPT) configs in ground_truth_worker.py, so
generating them again would be a config-file name collision by construction.

    P2  confirmed glossary terms (latin side), in glossary.json's own order.
    P3  top-20 latin terms by frequency in gold.jsonl, ties broken
        alphabetically. Single-character tokens are dropped: the one that
        showed up ("l") turned out to be a normalize() artifact of splitting
        "L-теаниль" on its hyphen, not a technical term.
    P4  P3's term set, reworded as one connected sentence in the corpus's
        own register (comma-chained clauses, "Смотри, ..." opener) instead
        of a bare list -- calibrated against real gold.jsonl transcripts,
        not invented from scratch. This part is authored, not derived: no
        script can write natural Russian, only cite where its vocabulary
        came from.
    P5  P4 split into several sentences with periods and an em-dash, so the
        prompt also demonstrates end-of-sentence punctuation, not just
        commas.

Only P2/P3 (mechanical lists) are safe to regenerate unattended if the source
data changes. P4/P5 will keep whatever term set P3 currently computes to, but
re-running this after gold.jsonl grows should have a human re-read the P4/P5
sentence, not blindly trust that every new term still fits it.

    ./generate_stage2_prompts.py --out experiments/stage2_prompts.json
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ground_truth_text import normalize   # noqa: E402

DEFAULT_ROOT = Path.home() / "Library/Application Support/Soma/GroundTruth"
LATIN_WORD = re.compile(r"^[a-z0-9+#*]*[a-z][a-z0-9+#*]*$")
TOP_N = 20


def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def glossary_terms(root: Path) -> list[str]:
    """P2: the confirmed latin spellings, first-occurrence order, deduped.
    Empty on a fresh install (glossary.json starts empty) -- that is a real
    answer, not a bug, and the caller should skip P2 rather than fake one."""
    path = root / "glossary.json"
    if not path.exists():
        return []
    glossary = json.loads(path.read_text(encoding="utf-8"))
    seen: list[str] = []
    for spellings in glossary.values():
        for word in spellings:
            if word not in seen:
                seen.append(word)
    return seen


def top_latin_terms(root: Path, n: int = TOP_N) -> list[str]:
    """P3: highest-frequency latin words in gold.jsonl. Single-character
    tokens are excluded -- normalize() splits a hyphenated word like
    "L-теаниль" into two tokens, and the latin fragment left over is a
    tokenizer artifact, not a term anyone would want Whisper primed on."""
    counter: Counter[str] = Counter()
    for row in read_jsonl(root / "gold.jsonl"):
        for word in normalize(row.get("text", "")).split():
            if LATIN_WORD.match(word) and len(word) > 1:
                counter[word] += 1
    ranked = sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))
    return [word for word, _ in ranked[:n]]


# P4/P5 hand-authored sentence templates. {terms} is filled in with the P3
# term list, so if it's ever regenerated with the same 20 terms these render
# identically -- but a changed term set needs the wording re-read by a human.
P4_TEMPLATE = (
    "Смотри, сегодня делаю {open} {pr} и закрываю {issue} в {git}, "
    "чиню {ui} в {unity} и {android}, обсуждаем {nexus} и {housedata}, "
    "перехожу в {developer}, отправляю {email} про {project} и {mem}, "
    "добавляю {enum} и {input}, слушаю {hermes}, захожу в {facetime}, "
    "а ещё там {sirena}, {m1} и лишних {lines} кода."
)
P5_TEMPLATE = (
    "Смотри, сегодня делаю {open} {pr} и закрываю {issue} в {git}. "
    "Чиню {ui} в {unity} и {android}, обсуждаем {nexus} и {housedata}. "
    "Перехожу в {developer}, отправляю {email} про {project} и {mem}, "
    "добавляю {enum} и {input}. "
    "Слушаю {hermes}, захожу в {facetime} — а ещё там {sirena}, {m1} и лишних {lines} кода."
)
# How each P3 term is capitalized when it's used as a word in a sentence
# (P2/P3 themselves stay lowercase, exactly as extracted -- mechanical and
# reproducible). Acronyms upper-cased, proper nouns title-cased, ordinary
# loanwords left alone, matching how DEV_PROMPT itself writes "Git"/"API"
# next to lowercase "модель"/"промпт".
DISPLAY_CASE = {
    "pr": "PR", "ui": "UI", "m1": "M1", "git": "Git", "unity": "Unity",
    "android": "Android", "nexus": "Nexus", "housedata": "HouseData",
    "developer": "Developer", "hermes": "Hermes", "facetime": "FaceTime",
    "sirena": "Sirena",
}


def render_sentence(template: str, terms: list[str]) -> str:
    missing = [key for key in re.findall(r"\{(\w+)\}", template) if key not in terms]
    if missing:
        raise ValueError(f"P3's term set no longer covers the P4/P5 template: missing {missing}. "
                         "Re-read the sentence by hand before trusting a regenerated one.")
    return template.format(**{term: DISPLAY_CASE.get(term, term) for term in terms})


def build(root: Path) -> dict[str, dict]:
    glossary, top20 = glossary_terms(root), top_latin_terms(root)
    variants: dict[str, dict] = {}
    if glossary:
        variants["w-p-p2-v1"] = {"temperature": 0.0, "condition_on_previous_text": False,
                                 "initial_prompt": "Диктовка по разработке: " + ", ".join(glossary) + "."}
    if top20:
        variants["w-p-p3-v1"] = {"temperature": 0.0, "condition_on_previous_text": False,
                                 "initial_prompt": "Диктовка по разработке: " + ", ".join(top20) + "."}
        variants["w-p-p4-v1"] = {"temperature": 0.0, "condition_on_previous_text": False,
                                 "initial_prompt": render_sentence(P4_TEMPLATE, top20)}
        variants["w-p-p5-v1"] = {"temperature": 0.0, "condition_on_previous_text": False,
                                 "initial_prompt": render_sentence(P5_TEMPLATE, top20)}
    return variants


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    variants = build(args.root)
    if not variants:
        print("no glossary/gold data found -- nothing to generate", file=sys.stderr)
        return 1
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(variants, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    for name, options in variants.items():
        print(f"{name}: {options['initial_prompt']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

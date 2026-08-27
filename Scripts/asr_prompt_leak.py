#!/usr/bin/env python3
"""Stage 2.4: did a candidate prompt poison its own decodes?

Two independent failure modes to catch before a prompt variant ships:
(a) prompt leakage -- Whisper copies a chunk of the prompt into a file where
    those words were never said;
(b) hallucination-boilerplate creeping up -- the prompt nudges Whisper toward
    its stock "nothing here" behavior (empty text, low-confidence no_speech,
    a repeated-phrase loop) more often than the unprompted baseline does.

Neither reuses a hand-picked phrase blacklist ("Продолжение следует" and
friends): leakage is read straight off the prompt text actually used, and the
boilerplate signal is the exact no_speech threshold and repeats_itself() the
consensus voting in ground_truth_consensus.py already relies on -- not a
second, different definition of the same thing.

    ./asr_prompt_leak.py --decodes experiments/decodes-stage2-p3.jsonl \
        --config w-p-p3-v1 --prompts experiments/stage2_prompts.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ground_truth_consensus import NO_SPEECH_PROB  # noqa: E402
from ground_truth_text import normalize, repeats_itself  # noqa: E402

DEFAULT_ROOT = Path.home() / "Library/Application Support/Soma/GroundTruth"
LEAK_RUN = 3


def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def load_rows(path: Path, config: str) -> dict[str, dict]:
    """{file: row} for one config, skipping decode errors."""
    rows = {}
    for row in read_jsonl(path):
        if row.get("config") != config or row.get("error") not in (None, "None") or not row.get("file"):
            continue
        rows[row["file"]] = row
    return rows


def leaks_prompt(prompt: str, decode_text: str, gold_text: str, run: int = LEAK_RUN) -> bool:
    """True if `decode_text` contains a run of >= `run` consecutive prompt
    words where at least one of those words never appears anywhere in
    `gold_text` -- i.e. the file's true transcript.

    Checking only length-`run` windows is enough to catch any longer leaking
    run too: a run of length L >= run contains a length-`run` window that
    matches the same way.

    "At least one" word absent, not "all `run` words": the prompt is built
    from real vocabulary, so genuine speech could plausibly reuse one or two
    of its words by chance -- reusing all of them in the same order is what
    should not happen by accident. This is a safety check, not a verdict, so
    erring toward flagging more candidates is the deliberate choice.
    """
    prompt_words, decode_words = normalize(prompt).split(), normalize(decode_text).split()
    gold_words = set(normalize(gold_text).split())
    windows = {tuple(prompt_words[i : i + run]) for i in range(len(prompt_words) - run + 1)}
    return any(
        tuple(decode_words[i : i + run]) in windows
        and any(word not in gold_words for word in decode_words[i : i + run])
        for i in range(len(decode_words) - run + 1)
    )


def boilerplate_rates(rows: dict[str, dict]) -> dict:
    """Three independent signals of Whisper's stock failure modes, each a
    plain percentage of this config's decodes. None require gold, so they
    cover every file the config ran on, not just the ~100 gold ones."""
    n = len(rows)
    if not n:
        return {"n": 0, "empty_rate": None, "low_confidence_rate": None, "looping_rate": None}
    empty = sum(1 for row in rows.values() if not (row.get("text") or "").strip())
    low_confidence = sum(
        1
        for row in rows.values()
        if isinstance(row.get("no_speech"), (int, float)) and row["no_speech"] >= NO_SPEECH_PROB
    )
    looping = sum(1 for row in rows.values() if repeats_itself(normalize(row.get("text") or "")))
    return {
        "n": n,
        "empty_rate": round(100 * empty / n, 1),
        "low_confidence_rate": round(100 * low_confidence / n, 1),
        "looping_rate": round(100 * looping / n, 1),
    }


def check_leaks(rows: dict[str, dict], prompt: str, gold: dict[str, str]) -> list[str]:
    return sorted(
        name for name, row in rows.items() if name in gold and leaks_prompt(prompt, row.get("text") or "", gold[name])
    )


def report(config: str, rates: dict, leaked: list[str], checked_against_gold: int, baseline_rates: dict | None) -> None:
    print(f"config: {config}  ({rates['n']} decodes)")
    if checked_against_gold:
        pct = 100 * len(leaked) / checked_against_gold
        print(f"  prompt leak: {len(leaked)}/{checked_against_gold} gold files ({pct:.1f}%)")
        for name in leaked[:10]:
            print(f"    - {name}")
        if len(leaked) > 10:
            print(f"    ... and {len(leaked) - 10} more")
    else:
        print("  prompt leak: no gold overlap to check")
    for key, label in (
        ("empty_rate", "empty text"),
        ("low_confidence_rate", f"no_speech>={NO_SPEECH_PROB}"),
        ("looping_rate", "repeated-phrase loop"),
    ):
        now = rates[key]
        before = baseline_rates[key] if baseline_rates else None
        delta = ""
        if now is not None and before is not None:
            change = now - before
            delta = f"  (baseline {before:.1f}%, {'+' if change >= 0 else ''}{change:.1f})"
        cell = "-" if now is None else f"{now:.1f}"
        print(f"  {label}: {cell}%{delta}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--decodes", required=True, type=Path, help="experiment decodes.jsonl to check")
    parser.add_argument("--config", required=True, help="config name inside --decodes to check")
    parser.add_argument(
        "--prompts",
        type=Path,
        help="the --config-file JSON given to the worker; --config's initial_prompt is read from it",
    )
    parser.add_argument("--prompt", help="prompt text directly, instead of --prompts")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument(
        "--baseline-decodes",
        type=Path,
        help="decodes.jsonl holding --baseline-config (default: the cache under --root)",
    )
    parser.add_argument("--baseline-config", default="w-greedy")
    args = parser.parse_args()

    if args.prompt:
        prompt = args.prompt
    elif args.prompts:
        options = json.loads(args.prompts.read_text(encoding="utf-8"))
        prompt = (options.get(args.config) or {}).get("initial_prompt")
        if prompt is None:
            print(f"'{args.config}' has no initial_prompt in {args.prompts}", file=sys.stderr)
            return 1
    else:
        print("need --prompt or --prompts", file=sys.stderr)
        return 1

    rows = load_rows(args.decodes, args.config)
    if not rows:
        print(f"no '{args.config}' rows found in {args.decodes}", file=sys.stderr)
        return 1
    gold = {row["file"]: row["text"] for row in read_jsonl(args.root / "gold.jsonl")}
    leaked = check_leaks(rows, prompt, gold)
    checked = sum(1 for name in rows if name in gold)

    baseline_path = args.baseline_decodes or (args.root / "decodes.jsonl")
    baseline_rows = load_rows(baseline_path, args.baseline_config)
    baseline_rates = boilerplate_rates(baseline_rows) if baseline_rows else None

    report(args.config, boilerplate_rates(rows), leaked, checked, baseline_rates)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

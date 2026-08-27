#!/usr/bin/env python3
"""Stage-8: build auto-gold and a triaged review queue from the holdout decodes.

Hygiene rule (ASR_TUNING_PLAN.md #785): the MAIN decodes.jsonl and gold.jsonl are
read-only. Everything this script writes lives under experiments/.

Acceptance (validated on 215 human gold files, 2026-08-22): the naive "3-of-4
majority" rule was only 42% verbatim-correct on engine-DISPUTED files, and the
human gold corpus is 100% disagreement-selected (0/61 operation-review files had
all four engines agreeing), so its precision cannot measure the easy end.
The rule here is therefore conservative:

    ACCEPT (auto-gold) when the PRODUCTION PAIR agrees exactly — w-greedy ==
    gigaam-v2, two independent architectures — AND at least one independent
    confirmand (parakeet-tdt-v3 or gigaam-v3-rnnt) reads the same text.
    That is tier T1 (all four agree) or T2 (prod pair + one confirmand).

    REVIEW  everything else, triaged by informativeness:
      hard  - the prod pair itself disagrees, or fewer than 4 voices decoded
      easy  - a 3-majority exists but the prod pair is not both inside it

Output files (all under experiments/):
    gold-stage8-auto.jsonl      {"file","text","source":"stage8-consensus","tier"}
    review-queue-stage8.jsonl   {"file","tier":"hard"|"easy","edits",...}
    empty-stage8.jsonl           recordings with no usable speech in any voice
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ground_truth_text import normalize, wer  # noqa: E402

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_GT = Path.home() / "Library/Application Support/Soma/GroundTruth"

# holdout decode files -> canonical config names
VOICE_FILES = {
    "w-greedy": "decodes-stage8-holdout-wgreedy.jsonl",
    "gigaam": "decodes-stage8-holdout-gigaam.jsonl",
    "parakeet": "decodes-stage8-holdout-parakeet.jsonl",
    "rnnt": "decodes-stage8-holdout-rnnt.jsonl",
    "qwen3": "decodes-stage8-holdout-qwen.jsonl",
}
INDEPENDENT = ("parakeet", "rnnt", "qwen3")  # confirmands for the prod pair


def read_jsonl(path: Path):
    if not path.exists():
        return []
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    rows = [r for r in rows if r.get("event") == "decode" or "file" in r]
    return rows


def load_voices(exp: Path, with_qwen=False):
    """Successful decodes keyed by file, plus the set of files each voice RAN on
    (even unsuccessfully) — a file an engine attempted belongs in the review
    queue, not in silent disappearance from the intersection."""
    names = dict(VOICE_FILES)
    if not with_qwen:
        names.pop("qwen3")
    voices, attempted = {}, {}
    for cfg, fname in names.items():
        d, ran = {}, set()
        for row in read_jsonl(exp / fname):
            if "file" not in row:
                continue
            ran.add(row["file"])
            if row.get("error"):
                continue
            d[row["file"]] = (row.get("text") or "").strip()
        voices[cfg], attempted[cfg] = d, ran
    return voices, attempted


def build(out_dir: Path, exp: Path, with_qwen=False) -> int:
    voices, attempted = load_voices(exp, with_qwen)
    common = sorted(set.intersection(*[set(v) for v in voices.values()]))
    # A preflight may omit a zero-frame WAV from a later voice (Qwen does this),
    # so use the union, not an all-voices intersection, as the file universe.
    # Every observed recording must end up as auto-gold, review, or explicit
    # empty status — never silently vanish from this experimental materialization.
    observed = set.union(*[set(v) for v in attempted.values()]) if attempted else set()
    dropped = sorted(observed - set(common))
    if dropped:
        print(f"note: {len(dropped)} attempted file(s) lack one or more usable voices")
    print(f"holdout files with all voices: {len(common)}")

    gold_rows, queue_rows, empty_rows = [], [], []
    tiers = Counter()
    for f in common:
        texts = {k: voices[k][f] for k in voices}
        if all(not t for t in texts.values()):
            tiers["empty"] += 1
            empty_rows.append({"file": f, "status": "empty", "source": "stage8-preflight"})
            continue
        norms = {k: normalize(t) for k, t in texts.items() if t}
        if len(norms) < 4:
            tiers["review:<4 voices"] += 1
            queue_rows.append(_queue_row(f, texts, "hard", voices, exp))
            continue
        top, hits = Counter(norms.values()).most_common(1)[0]
        pair_ok = norms.get("w-greedy") == norms.get("gigaam") and bool(norms.get("w-greedy"))
        confirmations = [k for k in INDEPENDENT if k in norms and norms[k] == norms["w-greedy"]]
        if pair_ok and confirmations:
            tier = "T1" if hits == 4 else "T2"
            tiers[f"accept:{tier}"] += 1
            gold_rows.append({"file": f, "text": texts["w-greedy"],
                              "source": "stage8-consensus", "tier": tier,
                              "confirmed_by": ",".join(confirmations)})
        elif hits >= 3:
            pair_intact = pair_ok  # 3-majority with prod pair both inside
            tier = "easy" if pair_intact else "hard"
            tiers[f"review:{tier}"] += 1
            queue_rows.append(_queue_row(f, texts, tier, voices, exp))
        else:
            tiers["review:hard"] += 1
            queue_rows.append(_queue_row(f, texts, "hard", voices, exp))
    for f in dropped:
        texts = {k: v[f] for k, v in voices.items() if f in v}
        if not any(texts.values()):
            tiers["empty"] += 1
            empty_rows.append({"file": f, "status": "empty", "source": "stage8-preflight"})
        else:
            tiers["review:<4 voices"] += 1
            queue_rows.append(_queue_row(f, texts, "hard", voices, exp))

    print("\ntier counts:")
    for k in sorted(tiers):
        print(f"  {k:24s} {tiers[k]:5d}")

    gold_path = out_dir / "gold-stage8-auto.jsonl"
    queue_path = out_dir / "review-queue-stage8.jsonl"
    empty_path = out_dir / "empty-stage8.jsonl"
    gold_path.write_text(
        "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in gold_rows),
        encoding="utf-8")
    queue_path.write_text(
        "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in queue_rows),
        encoding="utf-8")
    empty_path.write_text(
        "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in empty_rows),
        encoding="utf-8")
    print(f"\nwrote {len(gold_rows)} auto-gold rows -> {gold_path}")
    print(f"wrote {len(queue_rows)} review rows -> {queue_path}")
    print(f"wrote {len(empty_rows)} empty rows -> {empty_path}")
    return 0


def _queue_row(f, texts, tier, voices, exp):
    """Review queue entry with word-level triage info."""
    norms = {k: normalize(t) for k, t in texts.items() if t}
    ref = norms.get("w-greedy", "")
    edits = {}
    import difflib
    for k, n in norms.items():
        if k == "w-greedy":
            continue
        sm = difflib.SequenceMatcher(None, ref, n)
        edits[k] = sum(1 for tag, *___ in sm.get_opcodes() if tag != "equal")
    return {"file": f, "tier": tier, "edits": edits,
            "texts": {k: t[:300] for k, t in texts.items()}}


def load_corpus_a_voices(gt: Path):
    """Corpus-A voices for sign tests against HUMAN gold: w-greedy/gigaam come
    from the read-only main cache, the stage-8 engines from their experiment
    files (corpus-A runs, not holdout)."""
    voices = {"parakeet": {}, "rnnt": {}}
    exp = gt / "experiments"
    for cfg, fname in (("parakeet", "decodes-stage8-parakeet.jsonl"),
                       ("rnnt", "decodes-stage8-gigaam-v3-rnnt.jsonl")):
        for row in read_jsonl(exp / fname):
            if row.get("event") == "decode" and not row.get("error"):
                voices[cfg][row["file"]] = (row.get("text") or "").strip()
    for cfg in ("w-greedy", "gigaam"):
        voices[cfg] = {}
        for row in read_jsonl(gt / "decodes.jsonl"):
            if row.get("config") == cfg and not row.get("error") and "file" in row:
                voices[cfg][row["file"]] = (row.get("text") or "").strip()
    return voices


def binom_p(wins: int, losses: int) -> float:
    """Two-sided exact binomial p for a win/loss split under a fair coin."""
    n = wins + losses
    if n == 0:
        return 1.0
    p = 0.5
    tail = sum(math.comb(n, k) * p**k * p**(n-k) for k in range(min(wins, losses) + 1)) * 2
    return min(1.0, tail)


def sign_tests(human_gold: dict[str, str], voices, corpus_files):
    """Engine-vs-engine sign tests on HUMAN gold only (no circularity)."""
    import math  # noqa: F401  (kept for callers; binom_p is module-level now)

    files = [f for f in corpus_files
             if f in human_gold and all(f in voices.get(k, {}) for k in ("w-greedy", "gigaam", "parakeet", "rnnt"))]
    print(f"\nsign-test files (human gold, all voices): {len(files)}")
    pairs = [("w-greedy", "gigaam"), ("w-greedy", "parakeet"), ("w-greedy", "rnnt"),
             ("gigaam", "parakeet"), ("gigaam", "rnnt"), ("parakeet", "rnnt")]
    print(f"{'pair':28s} {'wins-l':8s} {'wins-r':8s} {'ties':>5s} {'p':>8s}")
    for left, right in pairs:
        wl = wr = ties = 0
        for f in files:
            el = wer(normalize(human_gold[f]), normalize(voices[left][f]))
            er = wer(normalize(human_gold[f]), normalize(voices[right][f]))
            if el < er:
                wl += 1
            elif er < el:
                wr += 1
            else:
                ties += 1
        p = binom_p(wl, wr)
        flag = " *" if p < 0.05 else ""
        print(f"{left:13s} vs {right:13s} {wl:8d} {wr:8d} {ties:5d} {p:8.4f}{flag}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gt", type=Path, default=DEFAULT_GT,
                        help="GroundTruth root (gold.jsonl is read-only input)")
    parser.add_argument("--exp", type=Path, default=None,
                        help="experiments dir (default: <gt>/experiments)")
    parser.add_argument("--out", type=Path, default=None,
                        help="output dir (default: <gt>/experiments)")
    parser.add_argument("--with-qwen", action="store_true",
                        help="include the qwen3 holdout voice if it has finished")
    args = parser.parse_args()
    exp = args.exp or args.gt / "experiments"
    out = args.out or exp
    human = {}
    for row in read_jsonl(args.gt / "gold.jsonl"):
        if row.get("source") in ("operation-review", "review-session"):
            human[row["file"]] = row["text"]
    print(f"human gold (input, read-only): {len(human)}")
    corpus_voices = load_corpus_a_voices(args.gt)
    corpus_files = sorted(
        set.intersection(*[set(corpus_voices[k]) for k in ("w-greedy", "gigaam", "parakeet", "rnnt")])
        & set(human))
    sign_tests(human, corpus_voices, corpus_files)
    return build(out, exp, args.with_qwen)


if __name__ == "__main__":
    raise SystemExit(main())

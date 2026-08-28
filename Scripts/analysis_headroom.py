#!/usr/bin/env python3
"""Decision analysis: oracle ceiling, residual taxonomy, statistical power.

Answers: is there anything left in decode settings, or do we need different
data? Written 2026-08-20 for the 'should we keep tuning' question.
"""

from __future__ import annotations

import difflib
import json
import math
import os
import re
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ground_truth_paths import LEGACY_ROOT
from ground_truth_text import normalize, wer  # noqa: E402

GT = str(LEGACY_ROOT)
CUR = "w-bo-t20-n10-v1-veto_v2"


def load_multi(path: str) -> dict:
    out: dict = {}
    with open(path) as f:
        for line in f:
            r = json.loads(line)
            if "file" not in r:
                continue
            out.setdefault(r.get("config", "?"), {})[r["file"]] = r.get("text", "")
    return out


cfgs: dict = {}
for p in [
    "decodes.jsonl",
    "experiments/decodes-stage2-prompts.jsonl",
    "experiments/decodes-stage3-bo10.jsonl",
    "experiments/decodes-stage3-bo3.jsonl",
    "experiments/decodes-stage3-turbo.jsonl",
    "experiments/decodes-stage5b-veto-v2.jsonl",
]:
    full = os.path.join(GT, p)
    if os.path.exists(full):
        cfgs.update(load_multi(full))

gold: dict = {}
with open(os.path.join(GT, "gold.jsonl")) as f:
    for line in f:
        r = json.loads(line)
        if "file" in r:
            gold[r["file"]] = r.get("text", "")

refs = {f: normalize(t) for f, t in gold.items() if normalize(t).split()}


def W(name: str, f: str) -> float:
    return wer(refs[f], normalize(cfgs.get(name, {}).get(f, "")))


# ---- 1) Oracle: best config per file over the whole pool ------------------
cur_wers, oracle_wers = [], []
winners: dict = {}
v2_best = 0
for f in refs:
    w = {n: W(n, f) for n in cfgs}
    cur_wers.append(w[CUR])
    oracle_wers.append(min(w.values()))
    bw = [n for n in w if abs(w[n] - min(w.values())) < 1e-9]
    if CUR in bw:
        v2_best += 1
    else:
        top = sorted(bw, key=lambda x: -len(cfgs[x]))[0]
        winners[top] = winners.get(top, 0) + 1

print("== 1) ORACLE (upper bound of any per-file config selection/ensemble) ==")
print(f"pool: {len(cfgs)} configs | gold refs: {len(refs)}")
print(f"current v2 median WER : {statistics.median(cur_wers):.4f}")
print(f"oracle median WER     : {statistics.median(oracle_wers):.4f}")
print(f"v2 is (tied-)best on {v2_best}/{len(refs)} files")
print(f"when v2 loses, winner: {sorted(winners.items(), key=lambda x: -x[1])[:6]}")

# ---- 2) Taxonomy of residual errors under v2 ------------------------------
FILLERS = {
    "ну",
    "э",
    "ээ",
    "мм",
    "ага",
    "угу",
    "вот",
    "типа",
    "короче",
    "значит",
    "прям",
    "просто",
    "да",
    "как бы",
    "то есть",
}
NORM_FILL = {w.replace(" ", "") for w in FILLERS}


def bucket(rw, hw):
    for w in (rw, hw):
        if w and re.search(r"[a-z]", w, re.I):
            return "latin/term"
    if (
        rw
        and hw
        and rw != hw
        and len(rw) > 3
        and len(hw) > 3
        and (rw[:4] == hw[:4] or difflib.SequenceMatcher(None, rw, hw).ratio() > 0.7)
    ):
        return "morphology"
    for w in (rw, hw):
        if w and w.replace(" ", "") in NORM_FILL:
            return "filler"
    return "lexical/real"


tot_len = tot_err = 0
berr: dict = {}
files_bad = 0
examples: dict = {k: [] for k in ("latin/term", "morphology", "filler", "lexical/real")}
for f, ref in refs.items():
    hyp = normalize(cfgs[CUR].get(f, "")).split()
    refw = ref.split()
    sm = difflib.SequenceMatcher(None, refw, hyp, autojunk=False)
    ops = 0
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        n = max(i2 - i1, j2 - j1)
        ops += n
        for k in range(n):
            rw = refw[i1 + k] if i1 + k < i2 else None
            hw = hyp[j1 + k] if j1 + k < j2 else None
            b = bucket(rw, hw)
            berr[b] = berr.get(b, 0) + 1
            ex = examples[b]
            if len(ex) < 8:
                if rw and hw:
                    ex.append(f"{rw}->{hw}")
                elif rw:
                    ex.append(f"-{rw}")
                elif hw:
                    ex.append(f"+{hw}")
    tot_len += len(refw)
    tot_err += ops
    if ops:
        files_bad += 1

print()
print(f"== 2) RESIDUAL ERRORS under v2 ({files_bad}/{len(refs)} files imperfect) ==")
print(f"aggregate WER = {tot_err}/{tot_len} = {tot_err / tot_len:.4f}")
for b, c in sorted(berr.items(), key=lambda x: -x[1]):
    fixed = (tot_err - c) / tot_len
    print(f"  {b:13} {c:4} err-words ({100 * c / tot_err:3.0f}%)  WER if fixed={fixed:.4f}  e.g. {examples[b][:6]}")

# ---- 3) Statistical power: what delta can n=98 detect? -------------------
print()
print("== 3) POWER: minimum detectable WER delta at n gold files ==")


# sign-test resolution: with n paired files, the smallest win/loss split that
# reaches p<0.05 (two-sided binomial) — computed exactly.
def sig_threshold(n):
    """Smallest wins-losses margin over n discordant pairs that reaches
    two-sided p<0.05 (exact binomial on the sign test)."""
    from math import comb

    total = 2.0**n
    for margin in range(n % 2, n + 1, 2):
        wins = (n + margin) // 2
        p = 2 * (1 - sum(comb(n, i) for i in range(0, wins)) / total)
        if p < 0.05:
            return margin
    return None


cur_sorted = sorted(cur_wers)
n = len(refs)
base_med = statistics.median(cur_wers)
# how many files would have to flip from median-level error to zero to move
# the median by delta: simulation over the observed distribution.
print(f"n={n}, current median={base_med:.4f}")
print(f"sign-test needs roughly wins-losses >= {sig_threshold(n)} (of possible flips)")
for target in (0.010, 0.005, 0.003, 0.001):
    # count files whose WER > target that would need to improve to <= target
    need = sum(1 for w in cur_wers if w > target)
    print(f"  to reach median {target:.3f}: {need}/{n} files must drop to <= that level")

# ---- 4) What extra data would buy: spot coverage estimate ----------------
print()
print("== 4) DATA-VALUE: error mass vs file frequency ==")
per_file = sorted(refs.keys(), key=lambda f: -W(CUR, f))
worst10 = per_file[:10]
w_mass = sum(min(W(CUR, f), 1.0) for f in worst10)
tot_mass = sum(min(W(CUR, f), 1.0) for f in refs)
print(f"worst 10 files carry {w_mass:.2f} of {tot_mass:.2f} total error mass ({100 * w_mass / tot_mass:.0f}%)")
for f in worst10:
    print(f"  {f}: WER {W(CUR, f):.3f} | gold: {gold[f][:70]!r}")

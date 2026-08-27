#!/usr/bin/env python3
"""Did that change make recognition better or worse?

The review queue was abandoned at 2467 unanswered operations, so there will
never be a complete reference corpus. This scores against what a human DID
settle — 99 gold transcripts and 128 adjudicated disagreement spots — plus two
label-free signals that cover all 991 recordings and cost nothing to recompute.

Absolute numbers here are not truth. Gold rows were chosen from engine output,
so they flatter the engines; the spot set is small and lives only where engines
already disagreed. What the harness IS good for is direction: run it before a
change, run it after, and read the delta.

    ./asr_eval.py                          # score every config in the cache
    ./asr_eval.py --save baseline.json     # freeze today's numbers
    ./asr_eval.py --baseline baseline.json # what moved, and which way
    ./asr_eval.py --decodes new_run.jsonl  # score an experiment
"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ground_truth_text import normalize, wer  # noqa: E402

DEFAULT_ROOT = Path.home() / "Library/Application Support/Soma/GroundTruth"
REFERENCE = "gigaam"  # the independent architecture, hence the drift anchor
LATIN = re.compile(r"[A-Za-z]")
PUNCT = re.compile(r"[.,!?;:]")

# Higher is better for these; every other metric is an error rate.
GOOD_WHEN_UP = {"spots", "latin", "punct"}


def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            rows.append(json.loads(line))
    return rows


HUMAN_SOURCES = {"operation-review", "review-session"}


def load_gold(path: Path, include_auto: bool = False) -> dict[str, str]:
    """Load only human references by default; consensus rows are circular for
    the engines that produced them and must be an explicit opt-in."""
    return {row["file"]: row["text"] for row in read_jsonl(path) if include_auto or row.get("source") in HUMAN_SOURCES}


def load_decodes(paths: list[Path]) -> dict[str, dict[str, str]]:
    """{file: {config: text}}, skipping rows where the engine errored.

    Takes a list, not one path, so an experiment file that only holds its
    own new config(s) can be merged with the main cache to pull in the
    REFERENCE (gigaam) rows drift needs -- an experiment's own file never
    contains gigaam, since hygiene rule 1 forbids decoding into it."""
    decodes: dict[str, dict[str, str]] = {}
    for path in paths:
        for row in read_jsonl(path):
            if row.get("error") not in (None, "None") or not row.get("file"):
                continue
            decodes.setdefault(row["file"], {})[row["config"]] = row.get("text") or ""
    return decodes


def contains(haystack: str, needle: str) -> bool:
    """Is this exact word sequence somewhere in that transcript?

    Word-level rather than character-level: a substring test would count "он"
    as present inside "она", which is precisely the kind of one-letter call the
    spot set exists to measure.
    """
    words, wanted = normalize(haystack).split(), normalize(needle).split()
    if not wanted:
        return True
    return any(words[i : i + len(wanted)] == wanted for i in range(len(words) - len(wanted) + 1))


def spot_answers(verdicts: list[dict], progress: list[dict]) -> list[dict]:
    """Pair each human decision with the readings that decision rejected.

    A decision to delete a word carries an empty text, so it cannot be scored
    by looking for what the listener chose — there is nothing to look for. It
    is scored by the absence of what they threw away, which means the rejected
    readings have to be recovered from the verdict that posed the question.
    """
    options: dict[str, list[str]] = {}
    for verdict in verdicts:
        for operation in verdict.get("review_operations") or []:
            options[operation.get("signature")] = [
                str(alternative.get("text", "")) for alternative in operation.get("alternatives") or []
            ]
    answers = []
    for row in progress:
        alternatives = options.get(row.get("signature"))
        if alternatives is None:
            continue  # the question was re-cut since; its answer no longer maps
        chosen = row.get("text", "")
        rejected = [text for text in alternatives if normalize(text) != normalize(chosen) and normalize(text)]
        if not chosen.strip() and not rejected:
            continue
        answers.append({"file": row["file"], "chosen": chosen, "rejected": rejected})
    return answers


def spot_score(text: str, answer: dict) -> bool:
    if answer["chosen"].strip():
        return contains(text, answer["chosen"])
    # Deletion: credit only if none of the discarded readings survived.
    return not any(contains(text, reading) for reading in answer["rejected"])


def score(decodes: dict[str, dict[str, str]], gold: dict[str, str], answers: list[dict]) -> dict[str, dict[str, float]]:
    configs = sorted({config for row in decodes.values() for config in row})
    results = {}
    for config in configs:
        texts = {name: row[config] for name, row in decodes.items() if config in row}
        if not texts:
            continue
        # Kept per-file (not just averaged) so a baseline comparison can run a
        # sign test instead of eyeballing a mean delta against noise — at 94-99
        # gold files a 0.002 shift in the average is meaningless on its own.
        wer_by_file = {
            name: wer(normalize(reference), normalize(texts[name]))
            for name, reference in gold.items()
            if name in texts and normalize(reference).split()
        }
        drift_by_file = {
            name: wer(normalize(row[REFERENCE]), normalize(row[config]))
            for name, row in decodes.items()
            if REFERENCE in row and config in row and config != REFERENCE and normalize(row[REFERENCE]).split()
        }
        errors, drift = list(wer_by_file.values()), list(drift_by_file.values())
        hits = [spot_score(texts[answer["file"]], answer) for answer in answers if answer["file"] in texts]
        results[config] = {
            "files": float(len(texts)),
            # median, not mean, for both (issue #0086 for drift, #0088 for
            # wer): wer() is unbounded above when the reference is short, so
            # a hallucinating candidate can score >1.0 on a single file. 6/98
            # gold files are 1-3 words; a handful of them was enough to pull
            # the mean WER to ~2x the median for nearly every config. A
            # word-count cutoff to exclude them would be one more number to
            # justify; the median just doesn't feel it.
            "wer": round(statistics.median(errors), 4) if errors else None,
            "wer_n": float(len(errors)),
            "spots": round(100 * sum(hits) / len(hits), 1) if hits else None,
            "spots_n": float(len(hits)),
            "drift": round(statistics.median(drift), 4) if drift else None,
            "latin": round(100 * sum(bool(LATIN.search(t)) for t in texts.values()) / len(texts), 1),
            "punct": round(100 * sum(bool(PUNCT.search(t)) for t in texts.values()) / len(texts), 1),
            "wer_by_file": wer_by_file,
            "drift_by_file": drift_by_file,
        }
    return results


# The counts are shown, not just the rates: w-offset only ever ran on the
# second tier, so its flattering WER is drawn from a handful of files and must
# not be read as beating a config that was scored on all of them.
COLUMNS = [
    ("files", "files", "{:.0f}"),
    ("wer_n", "gold", "{:.0f}"),
    ("wer", "WER↓", "{:.4f}"),
    ("spots_n", "spot", "{:.0f}"),
    ("spots", "spots%↑", "{:.1f}"),
    ("drift", "drift↓", "{:.4f}"),
    ("latin", "latin%↑", "{:.1f}"),
    ("punct", "punct%↑", "{:.1f}"),
]
RATES = {"wer", "spots", "drift", "latin", "punct"}


def cell(value, template: str) -> str:
    return "—" if value is None else template.format(value)


def delta(key: str, now, before) -> str:
    if now is None or before is None:
        return ""
    change = now - before
    if abs(change) < (0.05 if key in GOOD_WHEN_UP else 0.0005):
        return "  ="
    better = change > 0 if key in GOOD_WHEN_UP else change < 0
    return f"  {'+' if change > 0 else ''}{change:.4g} {'better' if better else 'WORSE'}"


def sign_test_p(wins: int, losses: int) -> float:
    """Exact two-sided binomial sign test: how likely is a split this lopsided
    (or more) under 'each file is a coin flip'? Ties are excluded before this
    is called — they carry no directional information.

    Each term computed via lgamma in log space, not math.comb(n, i) summed
    then multiplied by 0.5**n: that sum is a Python int with no size limit,
    but converting it to float to multiply does have one (~2**1024), and
    drift already scores the full corpus (n~956) -- one growth spurt past
    ~1024 files and every --baseline comparison would raise OverflowError
    instead of reporting a p-value. A multiplicative recurrence from i=0
    avoids that ceiling but trades it for a floor: its starting term 0.5**n
    itself underflows to a hard 0.0 once n is large enough, which then stays
    0.0 forever and silently answers "certain" for a coin-flip split. Each
    term computed independently via lgamma has neither failure mode.
    """
    n = wins + losses
    if n == 0:
        return 1.0
    k = min(wins, losses)
    log_total = math.lgamma(n + 1)
    log_half = n * math.log(2)

    def log_pmf(i: int) -> float:
        return log_total - math.lgamma(i + 1) - math.lgamma(n - i + 1) - log_half

    tail = sum(math.exp(log_pmf(i)) for i in range(k + 1))
    return min(1.0, 2 * tail)


def paired_verdict(title: str, now_by_file: dict | None, before_by_file: dict | None) -> str | None:
    """'wins 31 / losses 9 (n=40), p=0.0021' across files scored in both runs.

    Lower is better for both wer and drift, the only two callers — a file
    counts as a win when its error dropped. None when either side lacks
    per-file data (old baseline, pre-1.2) or no file overlaps without a tie.
    """
    if not now_by_file or not before_by_file:
        return None
    wins = losses = 0
    for name, before_error in before_by_file.items():
        now_error = now_by_file.get(name)
        if now_error is None or now_error == before_error:
            continue
        wins += now_error < before_error
        losses += now_error > before_error
    n = wins + losses
    if n == 0:
        return None
    return f"{title}: wins {wins} / losses {losses} (n={n}), p={sign_test_p(wins, losses):.3g}"


def report(results: dict, baseline: dict | None, baseline_config: str | None = None) -> None:
    header = f"{'config':14}" + "".join(f"{title:>10}" for _, title, _ in COLUMNS)
    print(header)
    print("-" * len(header))
    order = sorted(results, key=lambda c: (results[c]["wer"] is None, results[c]["wer"] or 0))
    for config in order:
        row = results[config]
        line = f"{config:14}" + "".join(f"{cell(row[key], fmt):>10}" for key, _, fmt in COLUMNS)
        print(line)
        # Same name in both runs (Этап 1's use case: did THIS config change
        # since it was frozen) by default; --baseline-config compares every
        # result against ONE fixed reference instead (Этап 2's use case: does
        # a brand-new config beat w-greedy, which never shared its name).
        reference = baseline.get(baseline_config or config) if baseline else None
        if reference:
            marks = [
                f"{title}{delta(key, row[key], reference.get(key))}"
                for key, title, _ in COLUMNS
                if key in RATES
                if delta(key, row[key], reference.get(key)).strip() not in ("", "=")
            ]
            if marks:
                print(" " * 14 + "  |  ".join(marks))
            for line in (
                paired_verdict("WER", row.get("wer_by_file"), reference.get("wer_by_file")),
                paired_verdict("drift", row.get("drift_by_file"), reference.get("drift_by_file")),
            ):
                if line:
                    print(" " * 14 + line)
    gold_n = max((row["wer_n"] for row in results.values()), default=0)
    spot_n = max((row["spots_n"] for row in results.values()), default=0)
    print(
        f"\nup to {gold_n:.0f} gold transcripts and {spot_n:.0f} adjudicated spots; "
        f"drift is median WER against {REFERENCE}, which needs no labels and so "
        f"covers every recording."
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--root", type=Path, default=DEFAULT_ROOT, help="GroundTruth directory holding gold/verdicts/progress"
    )
    parser.add_argument(
        "--decodes",
        type=Path,
        action="append",
        help="decodes.jsonl to score (default: the one under --root). Repeatable: an "
        "experiment file plus the main cache merges in gigaam for drift, since an "
        "experiment's own file never has it (hygiene rule 1).",
    )
    parser.add_argument("--baseline", type=Path, help="compare against these saved numbers")
    parser.add_argument(
        "--baseline-config",
        help="compare every config in --decodes against this ONE baseline config's frozen "
        "stats, instead of matching by identical name -- e.g. does a new prompt "
        "variant beat w-greedy, not 'has w-greedy itself changed since it was frozen'",
    )
    parser.add_argument("--save", type=Path, help="write the numbers for a later comparison")
    parser.add_argument("--json", action="store_true", help="emit the numbers instead of a table")
    parser.add_argument(
        "--include-auto-gold",
        action="store_true",
        help="include consensus-derived rows in WER (not valid for comparing engines that voted)",
    )
    args = parser.parse_args()

    sources = args.decodes or [args.root / "decodes.jsonl"]
    decodes = load_decodes(sources)
    if not decodes:
        print(f"no decodes found in {', '.join(str(p) for p in sources)}", file=sys.stderr)
        return 1
    gold = load_gold(args.root / "gold.jsonl", include_auto=args.include_auto_gold)
    answers = spot_answers(read_jsonl(args.root / "verdicts.jsonl"), read_jsonl(args.root / "review_progress.jsonl"))
    results = score(decodes, gold, answers)

    if args.save:
        args.save.write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8")
    if args.json:
        print(json.dumps(results, indent=2, ensure_ascii=False))
        return 0
    baseline = json.loads(args.baseline.read_text(encoding="utf-8")) if args.baseline else None
    report(results, baseline, args.baseline_config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

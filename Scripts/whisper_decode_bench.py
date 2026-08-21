#!/usr/bin/env python3
"""A/B the Whisper decode options against real Soma recordings.

mlx_whisper defaults to a six-temperature fallback: whenever a decoded window
trips `compression_ratio_threshold` or `logprob_threshold` it re-decodes the
same 30s window at a higher temperature, up to six times. It also feeds the
previous window's tokens back in via `condition_on_previous_text`.

Both are accuracy features that cost latency, and neither had ever been
measured on this workload. Run this before changing them, and again whenever
the model changes.

Usage (must run inside the engine venv):
    ~/…/venv-whisper/bin/python Scripts/whisper_decode_bench.py --limit 40
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
import time
from pathlib import Path

DEFAULT_RECORDINGS = Path.home() / "Library/Application Support/Soma/VoiceRecordings"
WHISPER_REPO = "mlx-community/whisper-large-v3-mlx"

# What the server ships today: every mlx_whisper default.
BASELINE: dict = {}
# The two proposed changes, measured separately — together they confound each
# other, and they turn out to have very different cost/benefit.
VARIANTS: dict[str, dict] = {
    "greedy": {"temperature": 0.0},  # drop the 6-temperature fallback
    "unconditioned": {"condition_on_previous_text": False},  # drop cross-window text priming
    "both": {"temperature": 0.0, "condition_on_previous_text": False},
}


def normalized(text: str) -> list[str]:
    return [re.sub(r"[^\w]+", "", word, flags=re.UNICODE).casefold() for word in text.split() if word.strip()]


def word_error_rate(reference: list[str], hypothesis: list[str]) -> float:
    """Levenshtein over words, normalised by reference length."""
    if not reference:
        return 0.0 if not hypothesis else 1.0
    previous = list(range(len(hypothesis) + 1))
    for i, ref_word in enumerate(reference, start=1):
        current = [i]
        for j, hyp_word in enumerate(hypothesis, start=1):
            current.append(
                min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (ref_word != hyp_word),
                )
            )
        previous = current
    return previous[-1] / len(reference)


def decode(audio, options: dict) -> tuple[str, float, float]:
    """Returns (text, seconds, max temperature any window fell back to)."""
    import mlx_whisper

    started = time.perf_counter()
    result = mlx_whisper.transcribe(audio, path_or_hf_repo=WHISPER_REPO, language="ru", **options)
    elapsed = time.perf_counter() - started
    temperatures = [segment.get("temperature", 0.0) for segment in result.get("segments", [])]
    return (result.get("text") or "").strip(), elapsed, max(temperatures, default=0.0)


def load_audio(path: Path):
    import numpy as np
    import soundfile as sf

    data, sample_rate = sf.read(str(path), dtype="float32")
    if getattr(data, "ndim", 1) > 1:
        data = data.mean(axis=1)
    if sample_rate != 16000:
        count = int(round(len(data) * 16000 / sample_rate))
        data = np.interp(
            np.linspace(0, len(data), count, endpoint=False),
            np.arange(len(data)),
            data,
        ).astype(np.float32)
    return np.ascontiguousarray(data), len(data) / 16000


def pick(recordings: Path, limit: int, min_seconds: float) -> list[Path]:
    """Spread the sample across the whole corpus, not just the newest files —
    the decoder fallback only fires on awkward audio, so a recency-biased
    sample under-reports it."""
    files = [
        path
        for path in sorted(recordings.glob("*.wav"), key=lambda p: p.stat().st_mtime)
        if path.stat().st_size >= min_seconds * 16000 * 2
    ]
    if len(files) <= limit:
        return files
    stride = len(files) / limit
    return [files[int(index * stride)] for index in range(limit)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recordings", type=Path, default=DEFAULT_RECORDINGS)
    parser.add_argument("--limit", type=int, default=30)
    parser.add_argument("--min-seconds", type=float, default=1.0)
    parser.add_argument("--json-out", type=Path, default=None)
    args = parser.parse_args(argv)

    paths = pick(args.recordings, args.limit, args.min_seconds)
    if not paths:
        print(f"no recordings found under {args.recordings}", file=sys.stderr)
        return 2
    print(f"benchmarking {len(paths)} recordings from {args.recordings}\n", flush=True)

    audio, _ = load_audio(paths[0])
    decode(audio, BASELINE)  # warm the model so the first timing is not a load

    rows = []
    for index, path in enumerate(paths, start=1):
        audio, duration = load_audio(path)
        base_text, base_seconds, base_temperature = decode(audio, BASELINE)
        row = {
            "file": path.name,
            "audio_seconds": round(duration, 2),
            "single_window": duration <= 30.0,
            "baseline_seconds": round(base_seconds, 3),
            "fallback_fired": base_temperature > 0.0,
            "baseline_text": base_text,
            "variants": {},
        }
        for name, options in VARIANTS.items():
            text, seconds, _ = decode(audio, options)
            row["variants"][name] = {
                "seconds": round(seconds, 3),
                "speedup": round(base_seconds / seconds, 2) if seconds else None,
                "identical": normalized(base_text) == normalized(text),
                "wer": round(word_error_rate(normalized(base_text), normalized(text)), 4),
                "text": text,
            }
        rows.append(row)
        print(
            f"{index:3}/{len(paths)}  {duration:6.1f}s  base {base_seconds:6.2f}s  "
            f"{'FALLBACK' if row['fallback_fired'] else '        '}  {_line(row)}",
            flush=True,
        )

    report(rows)
    if args.json_out:
        args.json_out.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"\nwrote {args.json_out}")
    return 0


def _verdict(result: dict) -> str:
    return "same text" if result["identical"] else f"WER {result['wer']:.3f}"


def _line(row: dict) -> str:
    parts = []
    for name in VARIANTS:
        result = row["variants"][name]
        verdict = "same" if result["identical"] else f"wer {result['wer']:.2f}"
        parts.append(f"{name} x{result['speedup']:.2f} {verdict}")
    return " | ".join(parts)


def report(rows: list[dict]) -> None:
    fallbacks = [r for r in rows if r["fallback_fired"]]
    total_base = sum(r["baseline_seconds"] for r in rows)

    print("\n" + "=" * 78)
    print(f"recordings                {len(rows)}   ({sum(1 for r in rows if r['single_window'])} fit one 30s window)")
    print(f"baseline total decode     {total_base:.1f}s")
    print(f"temperature fallback      fired on {len(fallbacks)}/{len(rows)} ({100 * len(fallbacks) / len(rows):.0f}%)")
    print()
    print(f"{'variant':<16}{'total':>9}{'speedup':>9}{'median':>9}{'identical':>12}{'mean WER*':>11}")
    for name in VARIANTS:
        results = [r["variants"][name] for r in rows]
        total = sum(x["seconds"] for x in results)
        identical = [x for x in results if x["identical"]]
        changed = [x for x in results if not x["identical"]]
        mean_wer = statistics.mean(x["wer"] for x in changed) if changed else 0.0
        print(
            f"{name:<16}{total:>8.1f}s{total_base / total:>8.2f}x"
            f"{statistics.median(x['speedup'] for x in results):>8.2f}x"
            f"{len(identical):>7}/{len(results):<4}{mean_wer:>11.4f}"
        )
    print("* mean WER is over the recordings that changed, versus the baseline transcript")

    if fallbacks:
        print(f"\nwhere the fallback actually fired ({len(fallbacks)} recording(s)):")
        for row in fallbacks:
            greedy = row["variants"]["greedy"]
            print(
                f"  {row['file']}  {row['audio_seconds']}s  "
                f"baseline {row['baseline_seconds']}s -> greedy {greedy['seconds']}s "
                f"(x{greedy['speedup']:.2f}), {_verdict(greedy)}"
            )

    for name in VARIANTS:
        changed = [r for r in rows if not r["variants"][name]["identical"]]
        if not changed:
            continue
        print(f"\n{name}: {len(changed)} transcript(s) changed, worst 3:")
        for row in sorted(changed, key=lambda r: -r["variants"][name]["wer"])[:3]:
            result = row["variants"][name]
            print(f"  {row['file']}  {row['audio_seconds']}s  WER {result['wer']:.3f}")
            print(f"    base: {row['baseline_text'][:160]}")
            print(f"    new : {result['text'][:160]}")
    print("=" * 78)


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Can the translator start before the recording finishes?

Today the LLM step cannot begin until every chunk has decoded and merged. But
chunks are cut at speech pauses, so each one is usually a whole clause — which
raises the question of whether they can be translated as they land instead.

This runs the real DeepSeek translate path both ways over recorded transcripts:

  full     one call on the merged transcript, which is what ships today
  chunked  one call per chunk, concatenated in order

and reports what actually matters — not total API time, but the time still left
after the user releases the key. In the chunked arm every chunk but the last has
already been translated while they were still speaking, so only the final chunk's
call remains.

RESULT (30 real recordings, deepseek-v4-flash, 2026-07-31): do not do this.

  translate time left after release   today  median 2.01s   streamed 1.46s
  saved                                      median 0.44s
  chunked vs full translation                mean WER 0.254, 20/30 over 0.20

The saving is small because the call is dominated by fixed overhead, not by
input length: a whole transcript costs about as much as its last chunk. It only
reaches ~1.5s on the longest recordings (5+ chunks), and those are exactly the
ones where translating a clause without its context degrades most. Quality loss
is visible, not just a wording difference -- see the samples the report prints.

The wider finding: the LLM step is ~2s median. It is not the dominant cost the
plan assumed, so there is little there to win.

Cost is small: ~0.11M tokens for 30 recordings both ways. Needs the app's key:
    export SOMA_DEEPSEEK_API_KEY="$(cat ~/Library/Application\\ Support/Soma/deepseek-api-key)"
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Soma"))

MODEL = "deepseek-v4-flash"


def normalized(text: str) -> list[str]:
    return [re.sub(r"[^\w]+", "", w, flags=re.UNICODE).casefold() for w in text.split() if w.strip()]


def word_error_rate(reference: list[str], hypothesis: list[str]) -> float:
    if not reference:
        return 0.0 if not hypothesis else 1.0
    previous = list(range(len(hypothesis) + 1))
    for i, ref in enumerate(reference, start=1):
        current = [i]
        for j, hyp in enumerate(hypothesis, start=1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ref != hyp)))
        previous = current
    return previous[-1] / len(reference)


def translate(text: str, timeout: float = 120.0) -> tuple[str, float]:
    from soma_language_optimizer_deepseek import _translate_general_prompt_deepseek

    started = time.perf_counter()
    result = _translate_general_prompt_deepseek(text, "ru", MODEL, "balanced", timeout)
    elapsed = time.perf_counter() - started
    return (result.get("translation") or "").strip(), elapsed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chunks-json", type=Path, default=Path("/tmp/merge_chunks.json"))
    parser.add_argument("--limit", type=int, default=30)
    parser.add_argument("--json-out", type=Path, default=None)
    args = parser.parse_args(argv)

    rows = json.load(open(args.chunks_json))[: args.limit]
    print(f"translating {len(rows)} recordings both ways with {MODEL}\n", flush=True)

    results = []
    for index, row in enumerate(rows, start=1):
        chunks = [c["text"] for c in row["chunk_texts"] if c["text"].strip()]
        if len(chunks) < 2:
            continue
        full_text, full_seconds = translate(row["merged_text"])
        if not full_text:
            print(f"{index:3}  full translation failed, skipping", flush=True)
            continue

        per_chunk, chunk_seconds = [], []
        for chunk in chunks:
            text, seconds = translate(chunk)
            per_chunk.append(text)
            chunk_seconds.append(seconds)
        if not all(per_chunk):
            print(f"{index:3}  a chunk translation failed, skipping", flush=True)
            continue

        chunked_text = " ".join(per_chunk).strip()
        entry = {
            "file": row["file"],
            "chunks": len(chunks),
            # today: nothing starts until the merge, so the whole call is tail latency
            "tail_today_seconds": round(full_seconds, 2),
            # proposed: every chunk but the last is already translated by release
            "tail_streamed_seconds": round(chunk_seconds[-1], 2),
            "chunk_seconds_total": round(sum(chunk_seconds), 2),
            "wer_vs_full": round(word_error_rate(normalized(full_text), normalized(chunked_text)), 4),
            "full_translation": full_text,
            "chunked_translation": chunked_text,
        }
        results.append(entry)
        print(f"{index:3}  {entry['chunks']} chunks   tail today {entry['tail_today_seconds']:5.2f}s"
              f"  ->  streamed {entry['tail_streamed_seconds']:5.2f}s"
              f"   wer(chunked vs full) {entry['wer_vs_full']:.3f}", flush=True)

    report(results)
    if args.json_out and results:
        args.json_out.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"\nwrote {args.json_out}")
    return 0 if results else 1


def report(results: list[dict]) -> None:
    if not results:
        print("no usable results")
        return
    today = [r["tail_today_seconds"] for r in results]
    streamed = [r["tail_streamed_seconds"] for r in results]
    saved = [a - b for a, b in zip(today, streamed)]

    print("\n" + "=" * 74)
    print(f"recordings                       {len(results)}")
    print(f"translate time left after release  today  median {statistics.median(today):5.2f}s  "
          f"mean {statistics.mean(today):5.2f}s")
    print(f"                               streamed  median {statistics.median(streamed):5.2f}s  "
          f"mean {statistics.mean(streamed):5.2f}s")
    print(f"  saved                                  median {statistics.median(saved):5.2f}s  "
          f"mean {statistics.mean(saved):5.2f}s")
    print(f"  total API time is higher when chunked  {statistics.mean(r['chunk_seconds_total'] for r in results):.1f}s "
          f"vs {statistics.mean(today):.1f}s per recording — that work just moves off the tail")
    print(f"\nchunked vs full translation      mean WER {statistics.mean(r['wer_vs_full'] for r in results):.4f}")
    print("  (two valid translations differ in wording, so this overstates damage;")
    print("   read the samples below before drawing a conclusion)")
    for row in sorted(results, key=lambda r: -r["wer_vs_full"])[:3]:
        print(f"\n  {row['file']}  WER {row['wer_vs_full']:.3f}")
        print(f"    full   : {row['full_translation'][:200]}")
        print(f"    chunked: {row['chunked_translation'][:200]}")
    print("=" * 74)


if __name__ == "__main__":
    raise SystemExit(main())

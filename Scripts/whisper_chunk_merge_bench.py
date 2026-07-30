#!/usr/bin/env python3
"""Measure how often the forced-chunk overlap join fails, and what it costs.

When speech runs past ~10s without a pause the client forces a chunk boundary
and replays 750ms of audio into the next chunk, so the two transcripts overlap.
The server stitches them with voice_transcript_merge.join_overlap, which needs
an exact normalised word run to match. When it does not match, the session is
flagged merge_safe=false and the client currently throws away every chunk it
already decoded and re-transcribes the whole recording from scratch.

This simulates that path on real recordings: cut at 10s with a 750ms replay,
decode each piece, then ask two questions.

  1. How often does the join actually fail?  (how often the cliff is hit)
  2. When it fails, what does simply accepting the concatenation cost, versus
     the whole-file transcript the fallback produces today?

Usage (must run inside the engine venv):
    ~/…/venv-whisper/bin/python Scripts/whisper_chunk_merge_bench.py --limit 25
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Soma"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import voice_transcript_merge as merge  # noqa: E402
from voice_chunk_simulator import capture_chunks  # noqa: E402

DEFAULT_RECORDINGS = Path.home() / "Library/Application Support/Soma/VoiceRecordings"
WHISPER_REPO = "mlx-community/whisper-large-v3-mlx"
SAMPLE_RATE = 16000
FORCED_CHUNK_SECONDS = 10.0     # VoicePauseDetector forces a boundary here
REPLAY_SECONDS = 0.75           # VoiceChunkCapture replays this into the next chunk


def word_error_rate(reference: list[str], hypothesis: list[str]) -> float:
    if not reference:
        return 0.0 if not hypothesis else 1.0
    previous = list(range(len(hypothesis) + 1))
    for i, ref_word in enumerate(reference, start=1):
        current = [i]
        for j, hyp_word in enumerate(hypothesis, start=1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ref_word != hyp_word)))
        previous = current
    return previous[-1] / len(reference)


def normalized(text: str) -> list[str]:
    return [merge.normalized_word(word) for word in text.split() if merge.normalized_word(word)]


def decode(audio) -> tuple[str, float]:
    import mlx_whisper

    started = time.perf_counter()
    result = mlx_whisper.transcribe(audio, path_or_hf_repo=WHISPER_REPO, language="ru")
    return (result.get("text") or "").strip(), time.perf_counter() - started


def load_audio(path: Path):
    import numpy as np
    import soundfile as sf

    data, rate = sf.read(str(path), dtype="float32")
    if getattr(data, "ndim", 1) > 1:
        data = data.mean(axis=1)
    if rate != SAMPLE_RATE:
        count = int(round(len(data) * SAMPLE_RATE / rate))
        data = np.interp(np.linspace(0, len(data), count, endpoint=False), np.arange(len(data)), data).astype(np.float32)
    return np.ascontiguousarray(data)


def join_overlap_fuzzy(existing: str, incoming: str, tolerance: float = 0.34) -> tuple[str, bool]:
    """Candidate replacement for merge.join_overlap.

    The replay window is 750ms, which routinely cuts a word in half: the tail of
    one chunk and the head of the next describe the same audio but need not
    tokenise identically. Requiring an exact word run therefore fails often. This
    accepts the longest overlap whose word-level edit distance is within
    `tolerance`, and still requires two words so a single common word cannot
    trigger a bogus join.
    """
    left, right = existing.split(), incoming.split()
    limit = min(len(left), len(right), merge.MAX_OVERLAP_WORDS)
    for count in range(limit, 1, -1):
        tail = [merge.normalized_word(word) for word in left[-count:]]
        head = [merge.normalized_word(word) for word in right[:count]]
        if word_error_rate(tail, head) <= tolerance:
            return " ".join(left + right[count:]).strip(), True
    return f"{existing} {incoming}".strip(), False


def merge_chunks(chunks: list[dict], joiner=None) -> tuple[str, bool, int]:
    """Mirrors voice_session_view.merge_locked: only a chunk that actually
    carries overlap is joined on a word run; pause chunks are plain appends."""
    merged, safe, failed = "", True, 0
    for chunk in chunks:
        incoming = " ".join(chunk["text"].split())
        if not incoming:
            continue
        if not merged:
            merged = incoming
            continue
        if chunk["overlap_ms"] > 0:
            merged, matched = (joiner or merge.join_overlap)(merged, incoming)
            if not matched:
                failed += 1
                safe = False
        else:
            merged = f"{merged} {incoming}".strip()
    return merged, safe, failed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recordings", type=Path, default=DEFAULT_RECORDINGS)
    parser.add_argument("--limit", type=int, default=25)
    parser.add_argument("--min-seconds", type=float, default=12.0, help="long enough that a forced boundary is possible")
    parser.add_argument("--json-out", type=Path, default=None)
    args = parser.parse_args(argv)

    files = [p for p in sorted(args.recordings.glob("*.wav"), key=lambda p: p.stat().st_mtime)
             if p.stat().st_size >= args.min_seconds * SAMPLE_RATE * 2]
    if not files:
        print(f"no recordings over {args.min_seconds}s under {args.recordings}", file=sys.stderr)
        return 2
    stride = max(1, len(files) // args.limit)
    paths = files[::stride][:args.limit]
    print(f"simulating forced chunking on {len(paths)} recordings\n", flush=True)

    decode(load_audio(paths[0])[:SAMPLE_RATE])  # warm the model

    rows = []
    for index, path in enumerate(paths, start=1):
        row = measure(load_audio(path), path)
        if row is None:
            print(f"{index:3}/{len(paths)}  no speech detected, skipping", flush=True)
            continue
        rows.append(row)
        print(f"{index:3}/{len(paths)}  {row['audio_seconds']:6.1f}s  {row['chunks']} chunks  "
              f"{row['failed_joins']}/{row['boundaries']} joins failed  "
              f"exact {'safe' if row['merge_safe'] else 'UNSAFE'}/wer {row['merged_vs_whole_wer']:.3f}  "
              f"fuzzy {row['fuzzy_failed_joins']}/{row['boundaries']} failed "
              f"{'safe' if row['fuzzy_merge_safe'] else 'UNSAFE'}/wer {row['fuzzy_vs_whole_wer']:.3f}", flush=True)

    report(rows)
    if args.json_out:
        args.json_out.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"\nwrote {args.json_out}")
    return 0


def measure(audio, path: Path) -> dict | None:
    """Chunk one recording the way the client would, decode every piece, then
    stitch it with both the shipping join and the tolerant candidate."""
    spans = capture_chunks(audio)
    if not spans:
        return None
    chunk_texts, chunk_seconds = [], 0.0
    for span in spans:
        text, seconds = decode(audio[span["start"]:span["end"]])
        chunk_texts.append({"text": text, "overlap_ms": span["overlap_ms"], "reason": span["reason"]})
        chunk_seconds += seconds
    merged, safe, failed = merge_chunks(chunk_texts)
    fuzzy_merged, fuzzy_safe, fuzzy_failed = merge_chunks(chunk_texts, join_overlap_fuzzy)
    whole_text, whole_seconds = decode(audio)
    return {
        "file": path.name,
        "audio_seconds": round(len(audio) / SAMPLE_RATE, 1),
        "chunks": len(spans),
        "boundaries": sum(1 for c in chunk_texts if c["overlap_ms"] > 0),
        "failed_joins": failed,
        "merge_safe": safe,
        "chunk_decode_seconds": round(chunk_seconds, 2),
        "whole_decode_seconds": round(whole_seconds, 2),
        # what the client used to pay when merge_safe was false: throw the chunk
        # work away and decode the whole file again
        "cliff_seconds": round(whole_seconds, 2) if not safe else 0.0,
        "merged_vs_whole_wer": round(word_error_rate(normalized(whole_text), normalized(merged)), 4),
        "fuzzy_failed_joins": fuzzy_failed,
        "fuzzy_merge_safe": fuzzy_safe,
        "fuzzy_vs_whole_wer": round(word_error_rate(normalized(whole_text), normalized(fuzzy_merged)), 4),
        "fuzzy_text": fuzzy_merged,
        "chunk_texts": chunk_texts,
        "merged_text": merged,
        "whole_text": whole_text,
    }


def report(rows: list[dict]) -> None:
    boundaries = sum(r["boundaries"] for r in rows)
    failed = sum(r["failed_joins"] for r in rows)
    unsafe = [r for r in rows if not r["merge_safe"]]

    print("\n" + "=" * 78)
    print(f"recordings                    {len(rows)}")
    print(f"forced boundaries             {boundaries}")
    print(f"joins that failed to match    {failed}/{boundaries} "
          f"({100 * failed / boundaries:.0f}%)" if boundaries else "")
    print(f"recordings flagged unsafe     {len(unsafe)}/{len(rows)} "
          f"({100 * len(unsafe) / len(rows):.0f}%)  <- these re-transcribe in full today")
    if unsafe:
        wasted = sum(r["cliff_seconds"] for r in unsafe)
        already = sum(r["chunk_decode_seconds"] for r in unsafe)
        print(f"  extra decode spent on them  {wasted:.1f}s on top of {already:.1f}s already decoded "
              f"({1 + wasted / already:.2f}x)")
        print(f"  WER if we just accepted it  {statistics.mean(r['merged_vs_whole_wer'] for r in unsafe):.4f} "
              f"(merged text vs the whole-file transcript)")
        print("\n  worst accepted-merge divergence:")
        for row in sorted(unsafe, key=lambda r: -r["merged_vs_whole_wer"])[:3]:
            print(f"    {row['file']}  {row['audio_seconds']}s  WER {row['merged_vs_whole_wer']:.3f}")
            print(f"      merged: {row['merged_text'][:150]}")
            print(f"      whole : {row['whole_text'][:150]}")
    fuzzy_failed = sum(r["fuzzy_failed_joins"] for r in rows)
    fuzzy_unsafe = [r for r in rows if not r["fuzzy_merge_safe"]]
    print("\n  --- candidate: tolerant overlap join ---")
    print(f"  joins that failed to match  {fuzzy_failed}/{boundaries} "
          f"({100 * fuzzy_failed / boundaries:.0f}%)" if boundaries else "")
    print(f"  recordings flagged unsafe   {len(fuzzy_unsafe)}/{len(rows)} "
          f"({100 * len(fuzzy_unsafe) / len(rows):.0f}%)")
    print(f"  WER vs whole file           {statistics.mean(r['fuzzy_vs_whole_wer'] for r in rows):.4f} "
          f"(exact join: {statistics.mean(r['merged_vs_whole_wer'] for r in rows):.4f})")

    safe = [r for r in rows if r["merge_safe"]]
    if safe:
        print(f"\nWER of a clean merge vs whole file  {statistics.mean(r['merged_vs_whole_wer'] for r in safe):.4f}")
    print("=" * 78)


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Whisper large-v3 MLX decoder for Layer 1 single or batch runs."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import mlx_whisper

REPO = "mlx-community/whisper-large-v3-mlx"


def decode(path: str) -> dict:
    result = mlx_whisper.transcribe(
        path,
        path_or_hf_repo=REPO,
        language="ru",
        temperature=0.0,
        condition_on_previous_text=False,
        word_timestamps=True,
    )
    words = [
        {
            "word": w.get("word", "").strip(),
            "start": round(float(w.get("start", 0.0)), 2),
            "end": round(float(w.get("end", 0.0)), 2),
        }
        for segment in (result.get("segments") or [])
        for w in (segment.get("words") or [])
        if w.get("word", "").strip()
    ]
    return {"text": (result.get("text") or "").strip(), "words": words, "version": "large-v3-mlx"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?")
    parser.add_argument("--manifest")
    args = parser.parse_args()
    if args.manifest:
        for row in map(json.loads, Path(args.manifest).read_text().splitlines()):
            result = decode(row["audio"])
            result["id"], result["file"] = row["id"], row["file"]
            print(json.dumps(result, ensure_ascii=False), flush=True)
    elif args.path:
        print(json.dumps(decode(args.path), ensure_ascii=False))
    else:
        parser.error("path or --manifest is required")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

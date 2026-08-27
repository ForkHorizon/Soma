#!/usr/bin/env python3
"""Run faster-whisper large-v3 over a Layer-1 manifest in one process."""
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    from faster_whisper import WhisperModel
    manifest = Path(sys.argv[1])
    rows = [json.loads(line) for line in manifest.read_text().splitlines() if line.strip()]
    model = WhisperModel("/Users/daliys/Daliys/AIModels/faster-whisper-large-v3",
                         device="cpu", compute_type="int8")
    for row in rows:
        segments, _ = model.transcribe(row["audio"], language="ru", beam_size=5,
                                       temperature=0.0, condition_on_previous_text=False,
                                       word_timestamps=True)
        words = []
        texts = []
        for segment in segments:
            texts.append(segment.text.strip())
            for word in (segment.words or []):
                if word.word.strip():
                    words.append({"word": word.word.strip(), "start": round(word.start, 2),
                                  "end": round(word.end, 2)})
        print(json.dumps({"id": row["id"], "file": row["file"],
                          "text": " ".join(t for t in texts if t), "words": words,
                          "version": "fw-large-v3-int8"}, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

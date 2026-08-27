#!/usr/bin/env python3
"""faster-whisper large-v3 decoder for Layer 1 (runs inside venv-fasterwhisper)."""

import json
import sys


def main() -> int:
    from faster_whisper import WhisperModel

    path = sys.argv[1]
    model = WhisperModel("/Users/daliys/Daliys/AIModels/faster-whisper-large-v3", device="cpu", compute_type="int8")
    segments, _ = model.transcribe(
        path, language="ru", beam_size=5, temperature=0.0, condition_on_previous_text=False, word_timestamps=True
    )
    words = []
    texts = []
    for segment in segments:
        texts.append(segment.text.strip())
        for word in segment.words or []:
            if word.word.strip():
                words.append({"word": word.word.strip(), "start": round(word.start, 2), "end": round(word.end, 2)})
    print(
        json.dumps(
            {"text": " ".join(t for t in texts if t), "words": words, "version": "fw-large-v3-int8"}, ensure_ascii=False
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

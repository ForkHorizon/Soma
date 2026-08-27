#!/usr/bin/env python3
"""Run GigaAM-Multilingual over a Layer-1 manifest in one process."""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Soma"))
from voice_asr_engines import transcribe_gigaam  # noqa: E402


def text_of(result) -> str:
    if isinstance(result, str):
        return result
    return getattr(result, "text", None) or " ".join(
        getattr(piece, "text", "") for piece in getattr(result, "pieces", [])
    ) or str(result)


def main() -> int:
    from transformers import AutoModel
    manifest = Path(sys.argv[1])
    rows = [json.loads(line) for line in manifest.read_text().splitlines() if line.strip()]
    model = AutoModel.from_pretrained("ai-sage/GigaAM-Multilingual", trust_remote_code=True)
    for row in rows:
        result = transcribe_gigaam(row["audio"], model)
        print(json.dumps({"id": row["id"], "file": row["file"],
                          "text": text_of(result).strip(), "words": [],
                          "version": "gigaam-multilingual"}, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

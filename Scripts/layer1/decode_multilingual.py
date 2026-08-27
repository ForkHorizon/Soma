#!/usr/bin/env python3
"""GigaAM-Multilingual decoder for Layer 1 (optional voice, venv-asr-eval)."""
import json
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Soma"))
from voice_asr_engines import transcribe_gigaam  # noqa: E402

def main() -> int:
    from transformers import AutoModel

    model = AutoModel.from_pretrained("ai-sage/GigaAM-Multilingual", trust_remote_code=True)
    text = transcribe_gigaam(sys.argv[1], model)
    print(json.dumps({"text": (text or "").strip(), "words": [],
                      "version": "gigaam-multilingual"}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

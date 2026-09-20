#!/usr/bin/env python3
"""GigaAM v2/v3 decoder for single or batch Layer-1 runs."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import warnings

warnings.filterwarnings("ignore")

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Soma"))
from voice_asr_engines import transcribe_gigaam  # noqa: E402

V2_MODELS = {"v2-rnnt": "rnnt", "v2-ctc": "ctc"}
V3_REVISIONS = {"v3-rnnt": "rnnt", "v3-e2e-ctc": "e2e_ctc"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?")
    parser.add_argument("variant")
    parser.add_argument("--manifest")
    args = parser.parse_args()
    rows = []
    if args.manifest:
        rows = [json.loads(line) for line in Path(args.manifest).read_text().splitlines() if line.strip()]
        paths = [row["audio"] for row in rows]
    elif args.path:
        paths = [args.path]
    else:
        parser.error("path or --manifest is required")

    if args.variant.startswith("v2"):
        import gigaam

        model = gigaam.load_model(V2_MODELS[args.variant])
    else:
        from transformers import AutoModel

        model = AutoModel.from_pretrained(
            "ai-sage/GigaAM-v3", revision=V3_REVISIONS[args.variant], trust_remote_code=True
        )

    for index, path in enumerate(paths):
        text = transcribe_gigaam(path, model)
        result = {"text": (text or "").strip(), "words": [], "version": f"gigaam-{args.variant}"}
        if rows:
            result["id"], result["file"] = rows[index]["id"], rows[index]["file"]
        print(json.dumps(result, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

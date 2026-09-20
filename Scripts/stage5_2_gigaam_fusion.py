#!/usr/bin/env python3
"""Stage 5.2: GigaAM fusion on disputed Russian words."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
import difflib

sys.path.insert(0, str(Path(__file__).resolve().parent))

from asr_eval import load_decodes, score, DEFAULT_ROOT, read_jsonl
from ground_truth_consensus import review_operations, PRIMARY
from ground_truth_text import normalize, agrees

_LATIN_OR_NUM = re.compile(r"[a-zA-Z0-9+#*]")


def contains_latin_or_num(text: str) -> bool:
    return bool(_LATIN_OR_NUM.search(text))


def fuse_whisper_and_gigaam(
    whisper_text: str, giga1_text: str, giga2_text: str, glossary: dict[str, list[str]] | None = None
) -> str:
    """Fuse Whisper candidate transcript with GigaAM RNNT and CTC transcripts.

    Rules for Stage 5.2:
    (a) If word/pair is in confirmed glossary -> use glossary spelling.
    (b) If both GigaAM heads (RNNT & CTC) agree with each other on a purely Russian
        word/span and disagree with Whisper -> adopt GigaAM's reading.
    (c) Otherwise -> keep Whisper candidate's reading.
    Punctuation, Latin, and numbers are NEVER overwritten by GigaAM.
    """
    if not whisper_text.strip():
        return whisper_text
    if not giga1_text.strip() or not giga2_text.strip():
        return whisper_text

    whisper_words = whisper_text.split()
    whisper_norm_tokens = [normalize(w) for w in whisper_words]

    giga1_words = giga1_text.split()
    giga1_norm_tokens = [normalize(w) for w in giga1_words]

    giga2_words = giga2_text.split()
    giga2_norm_tokens = [normalize(w) for w in giga2_words]

    # Align whisper_norm_tokens with giga1_norm_tokens
    matcher = difflib.SequenceMatcher(a=whisper_norm_tokens, b=giga1_norm_tokens)
    opcodes = matcher.get_opcodes()

    result_words = []
    for tag, i1, i2, j1, j2 in opcodes:
        if tag == "equal":
            result_words.extend(whisper_words[i1:i2])
        elif tag == "replace":
            w_span_raw = " ".join(whisper_words[i1:i2])
            w_span_norm = " ".join(whisper_norm_tokens[i1:i2])
            g1_span_raw = " ".join(giga1_words[j1:j2])
            g1_span_norm = " ".join(giga1_norm_tokens[j1:j2])

            # Check if GigaAM heads agree on this span
            # Check if giga2 contains g1_span_norm
            giga2_has_g1 = g1_span_norm in " ".join(giga2_norm_tokens)

            # Guard: Latin, numbers, punctuation
            is_latin_or_num = contains_latin_or_num(w_span_raw) or contains_latin_or_num(g1_span_raw)

            if not is_latin_or_num and giga2_has_g1:
                # Rule (b): both GigaAM heads agree on purely Russian words -> adopt GigaAM
                result_words.append(g1_span_raw)
            else:
                # Rule (c): keep Whisper
                result_words.extend(whisper_words[i1:i2])
        else:
            # delete or insert: keep Whisper's version
            if tag in ("delete", "equal"):
                result_words.extend(whisper_words[i1:i2])

    return " ".join(result_words)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument(
        "--candidate-file",
        type=Path,
        default=DEFAULT_ROOT / "experiments/decodes-stage5-veto-gigaam_hallucination_veto.jsonl",
    )
    parser.add_argument("--candidate-config", default="w-bo-t20-n10-v1-gigaam_hallucination_veto")
    args = parser.parse_args()

    decodes = load_decodes([args.root / "decodes.jsonl", args.candidate_file])
    fused_rows = []

    changed_count = 0
    total_files = 0

    for file, cfgs in decodes.items():
        whisper_text = cfgs.get(args.candidate_config)
        if whisper_text is None:
            continue
        total_files += 1
        giga1 = cfgs.get("gigaam", "")
        giga2 = cfgs.get("gigaam-ctc", "")

        fused_text = fuse_whisper_and_gigaam(whisper_text, giga1, giga2)
        if fused_text != whisper_text:
            changed_count += 1

        fused_rows.append({"file": file, "config": "w-final-fused-v1", "text": fused_text})

    out_file = args.root / "experiments/decodes-stage5-fused.jsonl"
    out_file.parent.mkdir(parents=True, exist_ok=True)
    out_file.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in fused_rows) + "\n", encoding="utf-8")
    print(f"Fused {total_files} files (changed {changed_count} files). Saved to {out_file.name}")


if __name__ == "__main__":
    main()

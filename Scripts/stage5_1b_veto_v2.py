#!/usr/bin/env python3
"""Stage 5.1b: hallucination veto v2 — word-sum silence + tail-credits trim.

Two fixes over the accepted 5.1 `gigaam_hallucination_veto`, both found by
auditing its survivors on the 956-file corpus:

  Rule A (near-silence): 5.1 called GigaAM "silent" only when BOTH heads were
  byte-empty. A single noise word from one head ("увеличиватся") was enough to
  shield a full Whisper loop (rec-1784763272, WER 28.0). v2 treats the summed
  word count of both heads as the silence signal: < NEAR_SILENCE_WORD_SUM
  words total means GigaAM heard no real speech. Triggers are unchanged from
  5.1 (no_speech / repeats / boilerplate), so short REAL speech that GigaAM
  mostly missed ("Открытка.", "Игры.") is still left alone.

  Rule B (tail credits): when GigaAM DID hear speech but Whisper appended
  hallucinated credits after the real content ("... Субтитры сделал
  DimaTorzok"), a file-level veto is wrong — it would throw away real speech.
  v2 trims only the final sentence, and only when ALL of:
    - every boilerplate match sits inside that one short final sentence,
    - the sentence is at most TAIL_SENTENCE_MAX_WORDS words (credits are
      2-5 words; a real closing sentence is not),
    - the matched phrase is NOT corroborated by GigaAM as a word sequence
      (the corpus contains real speech ABOUT hallucinations — "…виспер
      возвращает спасибо, либо продолжение следует. Мне не нравится…" —
      and GigaAM hears every word of it; that file must survive untouched).

Outputs a NEW experiment file; the 5.1 artifacts are never rewritten.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from asr_eval import DEFAULT_ROOT, contains, load_decodes, read_jsonl  # noqa: E402
from ground_truth_consensus import repeats_itself  # noqa: E402
from ground_truth_text import normalize  # noqa: E402

BOILERPLATE = re.compile(
    r"(?:субтитры|продолжение следует|продолжаю с сайта|скачиваю сайт|добавляю github|слушаю github)",
    re.IGNORECASE,
)
NEAR_SILENCE_WORD_SUM = 4  # < this many words across BOTH gigaam heads = silence
TAIL_SENTENCE_MAX_WORDS = 8  # hallucinated credits are short; real closings are not
SENTENCE_END = ".!?…"
V2_SUFFIX = "veto_v2"


def gigaam_word_sum(cfgs: dict[str, str]) -> int:
    """Total normalized words across both GigaAM heads for one file."""
    head1 = normalize(cfgs.get("gigaam", "")).split()
    head2 = normalize(cfgs.get("gigaam-ctc", "")).split()
    return len(head1) + len(head2)


def has_hallucination_trigger(text: str, no_speech: float) -> bool:
    """Same trigger set as the accepted 5.1 veto — unchanged on purpose."""
    return no_speech >= 0.4 or repeats_itself(normalize(text)) or bool(BOILERPLATE.search(text))


def corroborated_by_gigaam(phrase: str, cfgs: dict[str, str]) -> bool:
    """Did GigaAM also hear this exact word sequence? Then it is real speech."""
    return any(contains(cfgs.get(head, ""), phrase) for head in ("gigaam", "gigaam-ctc"))


def sentence_start_before(text: str, pos: int) -> int:
    """Index where the sentence containing text[pos] begins."""
    boundary = max(text.rfind(ch, 0, pos) for ch in SENTENCE_END)
    if boundary < 0:
        return 0
    start = boundary + 1
    while start < len(text) and text[start].isspace():
        start += 1
    return start


def trim_tail_credits(text: str, cfgs: dict[str, str]) -> str | None:
    """Drop a hallucinated credits sentence from the tail, or None to keep.

    None (not "") means "no safe trim" — the caller keeps the original text.
    """
    matches = list(BOILERPLATE.finditer(text))
    if not matches:
        return None
    start = sentence_start_before(text, matches[0].start())
    tail = text[start:]
    tail_words = normalize(tail).split()
    if not tail_words or len(tail_words) > TAIL_SENTENCE_MAX_WORDS:
        return None  # boilerplate is not confined to one short final sentence
    if any(corroborated_by_gigaam(m.group(0), cfgs) for m in matches):
        return None  # GigaAM heard these words too: real speech, keep them
    return text[:start].rstrip()


def apply_veto_v2(
    decodes: dict[str, dict[str, str]], no_speech_map: dict[tuple[str, str], float], candidate_cfg: str
) -> dict[str, dict[str, str]]:
    """Return a copy of decodes with the `<cfg>-veto_v2` config added per file."""
    out: dict[str, dict[str, str]] = {}
    for file, cfgs in decodes.items():
        row = dict(cfgs)
        out[file] = row
        cand_text = cfgs.get(candidate_cfg)
        if cand_text is None:
            continue
        ns = no_speech_map.get((file, candidate_cfg), 0.0)
        result = cand_text
        if gigaam_word_sum(cfgs) < NEAR_SILENCE_WORD_SUM:
            if has_hallucination_trigger(cand_text, ns):
                result = ""  # Rule A: hallucination on near-silence
        else:
            trimmed = trim_tail_credits(cand_text, cfgs)
            if trimmed is not None:
                result = trimmed  # Rule B: credits appended to real speech
        row[f"{candidate_cfg}-{V2_SUFFIX}"] = result
    return out


def no_speech_index(rows: list[dict]) -> dict[tuple[str, str], float]:
    index: dict[tuple[str, str], float] = {}
    for row in rows:
        file, cfg = row.get("file"), row.get("config")
        if file and cfg and row.get("no_speech") is not None:
            index[(file, cfg)] = row["no_speech"]
    return index


def main() -> int:
    parser = argparse.ArgumentParser(description="Hallucination veto v2: word-sum silence + tail-credits trim.")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--candidate-config", default="w-bo-t20-n10-v1")
    parser.add_argument("--candidate-file", type=Path, default=DEFAULT_ROOT / "experiments/decodes-stage3-bo10.jsonl")
    args = parser.parse_args()

    sources = [args.root / "decodes.jsonl", args.candidate_file]
    decodes = load_decodes(sources)
    rows = [r for p in sources for r in read_jsonl(p)]
    filtered = apply_veto_v2(decodes, no_speech_index(rows), args.candidate_config)
    cfg_name = f"{args.candidate_config}-{V2_SUFFIX}"

    out_rows = [
        {"file": file, "config": cfg_name, "text": cfgs[cfg_name]}
        for file, cfgs in filtered.items()
        if cfg_name in cfgs
    ]
    out_file = args.root / "experiments/decodes-stage5b-veto-v2.jsonl"
    out_file.parent.mkdir(parents=True, exist_ok=True)
    out_file.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in out_rows) + "\n", encoding="utf-8")

    vetoed = sum(1 for r in out_rows if not r["text"].strip())
    print(f"Saved {len(out_rows)} rows to {out_file.name} ({vetoed} empty)")
    for r in out_rows:
        cand = decodes[r["file"]].get(args.candidate_config, "")
        if r["text"] != cand:
            kind = "zeroed" if not r["text"].strip() else "trimmed"
            print(f"  {kind}: {r['file']}: {cand[-70:]!r} -> {r['text'][-70:]!r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

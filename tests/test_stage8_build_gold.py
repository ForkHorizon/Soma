#!/usr/bin/env python3
"""Tests for stage8_build_gold: acceptance tiers, queue triage, hygiene."""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Scripts"))

import stage8_build_gold as s8  # noqa: E402


def _write_voices(exp: Path, rows_by_config):
    for cfg, fname in s8.VOICE_FILES.items():
        if cfg in rows_by_config:
            p = exp / fname
            p.write_text(
                "\n".join(json.dumps(r, ensure_ascii=False) for r in rows_by_config[cfg]) + "\n", encoding="utf-8"
            )


def test_read_jsonl_skips_event_and_bad_lines(tmp_path):
    p = tmp_path / "x.jsonl"
    p.write_text('{"event": "loaded"}\n{"file": "a", "text": "t"}\nnot json\n', encoding="utf-8")
    rows = s8.read_jsonl(p)
    # The reader deliberately skips non-decode events as well as malformed rows.
    assert len(rows) == 1


def test_accept_tier1_prod_pair_plus_all_confirm(tmp_path):
    exp = tmp_path / "experiments"
    exp.mkdir()
    texts = {
        "w-greedy": "Привет, как дела?",
        "gigaam": "привет как дела",
        "parakeet": "Привет, как дела?",
        "rnnt": "привет как дела",
    }
    _write_voices(
        exp,
        {k: [{"event": "decode", "file": "a.wav", "config": k, "text": t, "error": None}] for k, t in texts.items()},
    )
    out = tmp_path / "out"
    out.mkdir()
    rc = s8.build(out, exp)
    assert rc == 0
    gold = [json.loads(line) for line in open(out / "gold-stage8-auto.jsonl")]
    queue = [json.loads(line) for line in open(out / "review-queue-stage8.jsonl")]
    assert len(gold) == 1 and gold[0]["tier"] == "T1"
    assert gold[0]["text"] == "Привет, как дела?"  # primary voice verbatim
    assert gold[0]["source"] == "stage8-consensus"
    assert queue == []


def test_prod_pair_split_goes_to_hard_review(tmp_path):
    exp = tmp_path / "experiments"
    exp.mkdir()
    texts = {
        "w-greedy": "открыть settings",
        "gigaam": "открыть сетингс",
        "parakeet": "открыть settings",
        "rnnt": "открыть сетингс",
    }
    _write_voices(
        exp,
        {k: [{"event": "decode", "file": "a.wav", "config": k, "text": t, "error": None}] for k, t in texts.items()},
    )
    out = tmp_path / "out"
    out.mkdir()
    s8.build(out, exp)
    gold = [json.loads(line) for line in open(out / "gold-stage8-auto.jsonl")]
    queue = [json.loads(line) for line in open(out / "review-queue-stage8.jsonl")]
    assert gold == []
    assert len(queue) == 1 and queue[0]["tier"] == "hard"


def test_error_rows_never_count_as_voices(tmp_path):
    exp = tmp_path / "experiments"
    exp.mkdir()
    rows = [
        {"event": "decode", "file": "a.wav", "config": k, "text": "привет", "error": None}
        for k in ("w-greedy", "gigaam")
    ]
    rows.append({"event": "decode", "file": "a.wav", "config": "parakeet", "text": "", "error": "RuntimeError"})
    rows.append({"event": "decode", "file": "a.wav", "config": "rnnt", "text": "", "error": "RuntimeError"})
    _write_voices(exp, {"w-greedy": rows[:1], "gigaam": rows[1:2], "parakeet": rows[2:3], "rnnt": rows[3:4]})
    out = tmp_path / "out"
    out.mkdir()
    s8.build(out, exp)
    gold = [json.loads(line) for line in open(out / "gold-stage8-auto.jsonl")]
    queue = [json.loads(line) for line in open(out / "review-queue-stage8.jsonl")]
    assert gold == []  # no confirmand -> not auto-accepted
    assert len(queue) == 1  # and not silently dropped
    assert queue[0]["tier"] == "hard"  # <4 voices


def test_three_majority_without_prod_pair_is_hard_not_accepted(tmp_path):
    # whisper+parakeet agree, gigaam disagrees: NOT accepted, hard review
    exp = tmp_path / "experiments"
    exp.mkdir()
    texts = {
        "w-greedy": "запусти тесты",
        "gigaam": "запусти тест",
        "parakeet": "запусти тесты",
        "rnnt": "запусти тесты",
    }
    _write_voices(
        exp,
        {k: [{"event": "decode", "file": "a.wav", "config": k, "text": t, "error": None}] for k, t in texts.items()},
    )
    out = tmp_path / "out"
    out.mkdir()
    s8.build(out, exp)
    gold = [json.loads(line) for line in open(out / "gold-stage8-auto.jsonl")]
    queue = [json.loads(line) for line in open(out / "review-queue-stage8.jsonl")]
    assert gold == []  # 3-of-4 alone never accepts
    assert len(queue) == 1 and queue[0]["tier"] == "hard"


def test_qwen_voice_optional_and_used_as_confirmand(tmp_path):
    exp = tmp_path / "experiments"
    exp.mkdir()
    texts = {"w-greedy": "привет", "gigaam": "привет", "parakeet": "пока", "rnnt": "пока", "qwen3": "привет"}
    _write_voices(
        exp,
        {k: [{"event": "decode", "file": "a.wav", "config": k, "text": t, "error": None}] for k, t in texts.items()},
    )
    out = tmp_path / "out"
    out.mkdir()
    s8.build(out, exp, with_qwen=True)
    gold = [json.loads(line) for line in open(out / "gold-stage8-auto.jsonl")]
    # prod pair agrees; parakeet/rnnt dissent; qwen confirms -> T2 accept
    assert len(gold) == 1 and gold[0]["tier"] == "T2"
    assert gold[0]["confirmed_by"] == "qwen3"


def test_qwen_preflight_omission_becomes_explicit_empty_not_disappearance(tmp_path):
    exp = tmp_path / "experiments"
    exp.mkdir()
    # Qwen receives no zero-frame WAV; the other engines report it as empty.
    rows = {
        k: [{"event": "decode", "file": "zero.wav", "config": k, "text": "", "error": None}]
        for k in ("w-greedy", "gigaam", "parakeet", "rnnt")
    }
    _write_voices(exp, rows)
    out = tmp_path / "out"
    out.mkdir()
    s8.build(out, exp, with_qwen=True)
    empty = [json.loads(line) for line in open(out / "empty-stage8.jsonl")]
    queue = [json.loads(line) for line in open(out / "review-queue-stage8.jsonl")]
    assert empty == [{"file": "zero.wav", "status": "empty", "source": "stage8-preflight"}]
    assert queue == []


def test_binom_p_two_sided():
    # 8 wins vs 0 losses: p = 2 * 0.5^8 = 0.0078125
    assert abs(s8.binom_p(8, 0) - 0.0078125) < 1e-9
    assert s8.binom_p(0, 0) == 1.0


def test_binom_p_mirrored_symmetry():
    assert abs(s8.binom_p(3, 9) - s8.binom_p(9, 3)) < 1e-12

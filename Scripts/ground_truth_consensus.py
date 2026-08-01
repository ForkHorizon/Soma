#!/usr/bin/env python3
"""Decide whether independent ASR systems agree well enough to call a
transcript ground truth.

The .txt saved next to each recording is NOT a reference: it is the live chunk
pipeline's own output, so scoring the pipeline against it can only ever return
100%. This module builds the missing reference from the one genuinely
independent signal available — a second ASR architecture that shares neither
weights nor training data with the first.

Pure and stdlib-only on purpose: the orchestrator imports it outside any engine
venv, and the voting rules are the part worth unit-testing.
"""
from __future__ import annotations

import re
import unicodedata

# Four Whisper decodes, ordered by how much each is trusted as the surface form
# to keep. They share an acoustic model, so their errors correlate — they are
# four opinions, not four independent votes, which is why GigaAM is required in
# every accepting rule below.
PRIMARY = "w-greedy"
WHISPER_CONFIGS = (PRIMARY, "w-prompt", "w-fallback", "w-sample")
GIGAAM = "gigaam"

# The engines never agree on surface form: GigaAM emits lowercase and
# unpunctuated, Whisper emits cased and punctuated. Comparing raw would report a
# disagreement on literally every file.
_PUNCT = re.compile(r"[^\w\s]", re.UNICODE)
_SPACE = re.compile(r"\s+")


def normalize(text: str) -> str:
    """Casefold, unify ё/е, drop punctuation, collapse whitespace.

    Digits are deliberately NOT spelled out. "5" versus "пять" is exactly the
    kind of difference a human should adjudicate, so leaving it in place routes
    those files to review instead of silently guessing one form.
    """
    folded = unicodedata.normalize("NFC", text or "").casefold().replace("ё", "е")
    return _SPACE.sub(" ", _PUNCT.sub(" ", folded)).strip()


_LATIN = re.compile(r"[a-z]")


def transliteration(reference_word: str, hypothesis_word: str) -> bool:
    """GigaAM's vocabulary is Russian-only, so it writes English terms out
    phonetically: unity -> юнити, assets -> асец, playground -> плейграунду.
    Whisper keeps the Latin spelling. That is a disagreement about script, not
    about what was said, and the Latin form is the one worth keeping — so it
    must not block acceptance. Cyrillic-vs-Cyrillic differences are never
    forgiven here: "проект" vs "проджект" is a real difference for a human."""
    return bool(_LATIN.search(hypothesis_word)) and not _LATIN.search(reference_word)


def unforgiven_edits(reference: str, hypothesis: str) -> int:
    """Word-level edit distance where a substitution costs nothing if it is only
    a transliteration."""
    ref, hyp = reference.split(), hypothesis.split()
    previous = list(range(len(hyp) + 1))
    for i, ref_word in enumerate(ref, start=1):
        current = [i]
        for j, hyp_word in enumerate(hyp, start=1):
            same = ref_word == hyp_word or transliteration(ref_word, hyp_word)
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (0 if same else 1)))
        previous = current
    return previous[-1]


def agrees(reference: str, hypothesis: str) -> bool:
    return unforgiven_edits(reference, hypothesis) == 0


def wer(reference: str, hypothesis: str) -> float:
    """Levenshtein over words, normalised by reference length."""
    ref, hyp = reference.split(), hypothesis.split()
    if not ref:
        return 0.0 if not hyp else 1.0
    previous = list(range(len(hyp) + 1))
    for i, ref_word in enumerate(ref, start=1):
        current = [i]
        for j, hyp_word in enumerate(hyp, start=1):
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (ref_word != hyp_word)))
        previous = current
    return previous[-1] / len(ref)


def repeats_itself(text: str, run: int = 6) -> bool:
    """Whisper's classic failure on silence and noise is one token repeated
    until the window ends. Every config can produce the same loop, so such a
    transcript can look unanimous and still be pure invention — it must never
    be accepted without a human looking at it."""
    words = text.split()
    streak = 1
    for previous, word in zip(words, words[1:]):
        streak = streak + 1 if word == previous else 1
        if streak >= run:
            return True
    return False


def _verdict(status: str, text: str, reason: str, **extra) -> dict:
    return {"status": status, "text": text, "reason": reason, **extra}


def decide(candidates: dict[str, str | None]) -> dict:
    """candidates maps config name -> transcript, or None if that decode failed.

    Returns a verdict dict with status accepted / review / empty / error.
    """
    primary, russian = candidates.get(PRIMARY), candidates.get(GIGAAM)
    if primary is None or russian is None:
        missing = [n for n in (PRIMARY, GIGAAM) if candidates.get(n) is None]
        return _verdict("error", "", f"no usable decode from: {', '.join(missing)}")

    norm = {name: normalize(text) for name, text in candidates.items() if text is not None}
    if not any(norm.values()):
        return _verdict("empty", "", "every engine reported no speech")
    silent = _hallucinated_over_silence(norm)
    if silent:
        return silent
    return _adjudicate(candidates, norm)


def _hallucinated_over_silence(norm: dict[str, str]) -> dict | None:
    """Whisper answers silence with a stock phrase — "Спасибо", "Продолжение
    следует" — while GigaAM correctly returns nothing. Treating that as a
    disagreement would fill the review queue with files that have no speech in
    them at all. A long Whisper transcript against an empty GigaAM is a
    different animal and still goes to review."""
    if norm.get(GIGAAM) != "":
        return None
    longest = max((len(text.split()) for name, text in norm.items() if name != GIGAAM), default=0)
    if longest > 4:
        return None
    return _verdict("empty", "", "gigaam heard nothing; whisper returned a stock phrase over silence")


def _adjudicate(candidates: dict[str, str | None], norm: dict[str, str]) -> dict:
    reference = norm[GIGAAM]
    agreeing = [name for name in WHISPER_CONFIGS if name in norm and agrees(reference, norm[name])]
    tried = [name for name in WHISPER_CONFIGS if name in norm]
    closest = min((wer(reference, norm[name]), name) for name in tried)
    # How many words a human would actually have to adjudicate. Most review
    # cases come down to one or two, and the panel sorts on this so the cheap
    # ones can be cleared in a single pass.
    edits = min(unforgiven_edits(reference, norm[name]) for name in tried)

    if not agreeing:
        unanimous = len({norm[name] for name in tried}) == 1
        hint = "whisper unanimous but gigaam dissents" if unanimous and len(tried) > 1 \
            else "no engine pair agrees"
        return _verdict("review", "", f"{hint} ({edits} word(s) differ, best WER {closest[0]:.3f} via {closest[1]})",
                        candidates=candidates, wer=round(closest[0], 4), edits=edits)

    text = candidates[agreeing[0]] or ""
    if repeats_itself(norm[agreeing[0]]):
        return _verdict("review", "", "engines agree on a repeated-token loop, which reads as a hallucination",
                        candidates=candidates, wer=0.0, edits=0)
    exact = agreeing[0] == PRIMARY and len(agreeing) == len(tried)
    if len(agreeing) < 2 and not exact:
        return _verdict("review", "", f"only {agreeing[0]} matches gigaam; the other whisper decodes disagree",
                        candidates=candidates, wer=round(closest[0], 4), edits=edits)
    return _verdict("accepted", text,
                    f"gigaam matches {len(agreeing)}/{len(tried)} whisper decodes ({', '.join(agreeing)})",
                    confidence="high" if exact or len(agreeing) >= 3 else "medium",
                    wer=0.0)


def needs_second_tier(candidates: dict[str, str | None]) -> bool:
    """After the cheap pass (w-greedy + gigaam), does this file justify paying
    for the three extra Whisper decodes? Only a disagreement does."""
    primary, russian = candidates.get(PRIMARY), candidates.get(GIGAAM)
    if primary is None or russian is None:
        return False
    return not agrees(normalize(russian), normalize(primary))

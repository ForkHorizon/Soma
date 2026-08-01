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

Glossary = dict[str, list[str]]


def cross_script(reference_word: str, hypothesis_word: str) -> bool:
    """GigaAM's vocabulary is Russian-only, so it writes English terms out
    phonetically: unity -> юнити, assets -> асец, go -> гоу. Whisper keeps the
    Latin spelling.

    This only REPORTS the shape; it never forgives on its own. Script alone is
    not evidence that two words are the same word — "unity" against "единица"
    looks identical to this test — and a blind rule would hide exactly the
    technical terms that matter most. The panel proposes these pairs, the
    listener confirms them against the audio, and only then do they enter the
    glossary."""
    return bool(_LATIN.search(hypothesis_word)) and not _LATIN.search(reference_word)


def same_word(reference_word: str, hypothesis_word: str, glossary: Glossary | None) -> bool:
    if reference_word == hypothesis_word:
        return True
    return hypothesis_word in (glossary or {}).get(reference_word, ())


def unforgiven_edits(reference: str, hypothesis: str, glossary: Glossary | None = None) -> int:
    """Word-level edit distance where a substitution costs nothing if the
    glossary says the two words are the same word."""
    ref, hyp = reference.split(), hypothesis.split()
    previous = list(range(len(hyp) + 1))
    for i, ref_word in enumerate(ref, start=1):
        current = [i]
        for j, hyp_word in enumerate(hyp, start=1):
            same = same_word(ref_word, hyp_word, glossary)
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (0 if same else 1)))
        previous = current
    return previous[-1]


def agrees(reference: str, hypothesis: str, glossary: Glossary | None = None) -> bool:
    return unforgiven_edits(reference, hypothesis, glossary) == 0


def proposed_terms(reference: str, hypothesis: str, glossary: Glossary | None = None) -> list[tuple[str, str]]:
    """Cross-script word pairs this file would need confirmed before the two
    engines could agree. These are what the review panel offers to the listener,
    never applied on their own."""
    import difflib

    ref, hyp = reference.split(), hypothesis.split()
    found = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(a=ref, b=hyp).get_opcodes():
        if tag != "replace" or i2 - i1 != 1 or j2 - j1 != 1:
            continue
        if cross_script(ref[i1], hyp[j1]) and not same_word(ref[i1], hyp[j1], glossary):
            found.append((ref[i1], hyp[j1]))
    return found


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


NO_SPEECH_PROB = 0.5      # measured: hallucination over silence 0.851, real speech 0.020
SILENT_PEAK_DB = -40.0    # nothing in this corpus reaches -40 dBFS and contains speech


def decide(candidates: dict[str, str | None], glossary: Glossary | None = None,
           metrics: dict | None = None) -> dict:
    """candidates maps config name -> transcript, or None if that decode failed.
    metrics carries Whisper's own no_speech/peak_db readings for the file.

    Returns a verdict dict with status accepted / review / empty / error.
    """
    primary, russian = candidates.get(PRIMARY), candidates.get(GIGAAM)
    if primary is None or russian is None:
        missing = [n for n in (PRIMARY, GIGAAM) if candidates.get(n) is None]
        return _verdict("error", "", f"no usable decode from: {', '.join(missing)}")

    norm = {name: normalize(text) for name, text in candidates.items() if text is not None}
    if not any(norm.values()):
        return _verdict("empty", "", "every engine reported no speech")
    silent = _hallucinated_over_silence(norm, metrics or {})
    if silent:
        return silent
    return _adjudicate(candidates, norm, glossary)


def _hallucinated_over_silence(norm: dict[str, str], metrics: dict) -> dict | None:
    """Whisper answers silence with a stock phrase — "Спасибо", "Продолжение
    следует". The old rule here guessed from transcript length, which is not
    evidence: a genuine "да" is short too.

    Whisper already knows. It reports no_speech_prob per segment, and on this
    corpus a hallucinated "Спасибо." scores 0.851 against 0.020 for real
    speech. Requiring GigaAM's independent silence as well means two engines
    and, where available, the waveform's own level all have to agree that
    nothing was said. Anything short of that goes to a human."""
    if norm.get(GIGAAM, "") != "":
        return None
    no_speech, peak = metrics.get("no_speech"), metrics.get("peak_db")
    if no_speech is None or no_speech < NO_SPEECH_PROB:
        return None
    detail = f"whisper no_speech={no_speech:.2f}, gigaam heard nothing"
    if peak is not None:
        detail += f", peak {peak:.0f} dBFS"
        if peak > SILENT_PEAK_DB and no_speech < 0.8:
            return None      # audible and Whisper is not certain — let a human hear it
    return _verdict("empty", "", detail)


def _adjudicate(candidates: dict[str, str | None], norm: dict[str, str],
                glossary: Glossary | None) -> dict:
    reference = norm[GIGAAM]
    agreeing = [name for name in WHISPER_CONFIGS
                if name in norm and agrees(reference, norm[name], glossary)]
    tried = [name for name in WHISPER_CONFIGS if name in norm]
    closest = min((wer(reference, norm[name]), name) for name in tried)
    # How many words a human would actually have to adjudicate. Most review
    # cases come down to one or two, and the panel sorts on this so the cheap
    # ones can be cleared in a single pass.
    edits = min(unforgiven_edits(reference, norm[name], glossary) for name in tried)
    terms = proposed_terms(reference, norm[closest[1]], glossary)

    if not agreeing:
        unanimous = len({norm[name] for name in tried}) == 1
        hint = "whisper unanimous but gigaam dissents" if unanimous and len(tried) > 1 \
            else "no engine pair agrees"
        return _verdict("review", "", f"{hint} ({edits} word(s) differ, best WER {closest[0]:.3f} via {closest[1]})",
                        candidates=candidates, wer=round(closest[0], 4), edits=edits, terms=terms)

    text = candidates[agreeing[0]] or ""
    if repeats_itself(norm[agreeing[0]]):
        return _verdict("review", "", "engines agree on a repeated-token loop, which reads as a hallucination",
                        candidates=candidates, wer=0.0, edits=0)
    exact = agreeing[0] == PRIMARY and len(agreeing) == len(tried)
    if len(agreeing) < 2 and not exact:
        return _verdict("review", "", f"only {agreeing[0]} matches gigaam; the other whisper decodes disagree",
                        candidates=candidates, wer=round(closest[0], 4), edits=edits, terms=terms)
    return _verdict("accepted", text,
                    f"gigaam matches {len(agreeing)}/{len(tried)} whisper decodes ({', '.join(agreeing)})",
                    confidence="high" if exact or len(agreeing) >= 3 else "medium",
                    wer=0.0)


def needs_second_tier(candidates: dict[str, str | None], glossary: Glossary | None = None) -> bool:
    """After the cheap pass (w-greedy + gigaam), does this file justify paying
    for the three extra Whisper decodes? Only a disagreement does."""
    primary, russian = candidates.get(PRIMARY), candidates.get(GIGAAM)
    if primary is None or russian is None:
        return False
    return not agrees(normalize(russian), normalize(primary), glossary)

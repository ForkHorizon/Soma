#!/usr/bin/env python3
"""How two transcripts are compared before anything votes on them.

Separated from the voting rules because these are different questions: this
module decides whether two strings say the same thing, `ground_truth_consensus`
decides whether that is enough to call one of them ground truth.
"""
from __future__ import annotations

import difflib
import re
import unicodedata

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

    This only REPORTS the shape; it never forgives on its own. "unity" against
    "единица" looks identical to this test, so a blind rule would hide errors on
    exactly the technical terms this corpus is full of. The panel proposes these
    pairs and the listener confirms them against the audio."""
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
    """Whisper's classic failure on silence is one token repeated until the
    window ends. Every config can produce the same loop, so the transcript can
    look unanimous and still be pure invention."""
    words = text.split()
    streak = 1
    for previous, word in zip(words, words[1:]):
        streak = streak + 1 if word == previous else 1
        if streak >= run:
            return True
    return False



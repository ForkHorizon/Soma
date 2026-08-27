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
#
# `+`, `#`, `*` used to be stripped like any other punctuation (issue
# #0070/GitHub#61), so "C++", "C#" and "C" all collapsed to "c" and errors on
# those technical terms were invisible to WER. Fixed point-wise: a run of
# these symbols survives only when it's glued to a letter/digit on at least
# one side; a bare "+" (e.g. "5 + 3") still strips as ordinary punctuation.
_SYMBOL_OR_PUNCT = re.compile(r"[+#*]+|[^\w\s]", re.UNICODE)
_SPACE = re.compile(r"\s+")


def normalize(text: str) -> str:
    """Casefold, unify ё/е, drop punctuation (keeping +/#/* glued to a word),
    collapse whitespace.

    Digits are deliberately NOT spelled out. "5" versus "пять" is exactly the
    kind of difference a human should adjudicate, so leaving it in place routes
    those files to review instead of silently guessing one form.
    """
    folded = unicodedata.normalize("NFC", text or "").casefold().replace("ё", "е")

    def strip_or_keep(match: re.Match) -> str:
        run = match.group()
        if run[0] not in "+#*":
            return " "
        start, end = match.span()
        glued_left = start > 0 and folded[start - 1].isalnum()
        glued_right = end < len(folded) and folded[end].isalnum()
        return run if glued_left or glued_right else " "

    stripped = _SYMBOL_OR_PUNCT.sub(strip_or_keep, folded)
    return _SPACE.sub(" ", stripped).strip()


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


_UNITS = {
    "ноль": 0,
    "один": 1,
    "одна": 1,
    "одну": 1,
    "два": 2,
    "две": 2,
    "три": 3,
    "четыре": 4,
    "пять": 5,
    "шесть": 6,
    "семь": 7,
    "восемь": 8,
    "девять": 9,
    "десять": 10,
    "одиннадцать": 11,
    "двенадцать": 12,
    "тринадцать": 13,
    "четырнадцать": 14,
    "пятнадцать": 15,
    "шестнадцать": 16,
    "семнадцать": 17,
    "восемнадцать": 18,
    "девятнадцать": 19,
    "двадцать": 20,
    "тридцать": 30,
    "сорок": 40,
    "пятьдесят": 50,
    "шестьдесят": 60,
    "семьдесят": 70,
    "восемьдесят": 80,
    "девяносто": 90,
    "сто": 100,
    "двести": 200,
    "триста": 300,
    "четыреста": 400,
    "пятьсот": 500,
    "шестьсот": 600,
    "семьсот": 700,
    "восемьсот": 800,
    "девятьсот": 900,
}
_SCALE = {"тысяча": 1000, "тысячи": 1000, "тысяч": 1000, "миллион": 10**6, "миллиона": 10**6, "миллионов": 10**6}


def canonical_numbers(words: list[str]) -> list[str]:
    """Fold spelled-out numerals to digits so notation stops reading as
    disagreement.

    "5" against "6" is a question about what was said; "24" against "двадцать
    четыре" is a question about how to write it, and only the first is worth a
    person's attention. Whisper writes digits, GigaAM writes words, so the
    engines differed on this in a third of the review queue while agreeing
    perfectly on the number.

    Digit tokens are deliberately NOT merged with each other: "2 3" stays two
    tokens while "два три" folds to 5. The asymmetry only ever costs a missed
    unification — it can never invent an agreement across the two notations,
    which is the direction that would matter."""
    folded: list[str] = []
    index = 0
    while index < len(words):
        word = words[index]
        if word.isdigit():
            folded.append(str(int(word)))
            index += 1
            continue
        if word not in _UNITS and word not in _SCALE:
            folded.append(word)
            index += 1
            continue
        total = group = 0
        while index < len(words) and (words[index] in _UNITS or words[index] in _SCALE):
            if words[index] in _SCALE:
                group = (group or 1) * _SCALE[words[index]]
                total += group
                group = 0
            else:
                group += _UNITS[words[index]]
            index += 1
        folded.append(str(total + group))
    return folded


def unforgiven_edits(reference: str, hypothesis: str, glossary: Glossary | None = None) -> int:
    """Word-level edit distance where a substitution costs nothing if the
    glossary says the two words are the same word."""
    ref, hyp = canonical_numbers(reference.split()), canonical_numbers(hypothesis.split())
    previous = list(range(len(hyp) + 1))
    for i, ref_word in enumerate(ref, start=1):
        current = [i]
        for j, hyp_word in enumerate(hyp, start=1):
            same = same_word(ref_word, hyp_word, glossary)
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (0 if same else 1)))
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
    ref, hyp = canonical_numbers(reference.split()), canonical_numbers(hypothesis.split())
    if not ref:
        return 0.0 if not hyp else 1.0
    previous = list(range(len(hyp) + 1))
    for i, ref_word in enumerate(ref, start=1):
        current = [i]
        for j, hyp_word in enumerate(hyp, start=1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ref_word != hyp_word)))
        previous = current
    return previous[-1] / len(ref)


def repeats_itself(text: str, span: int = 6, longest: int = 4) -> bool:
    """Whisper's classic failure on silence is a loop that runs until the window
    ends. Every config can produce the same one, so the transcript can look
    unanimous and still be pure invention.

    The loop is not always a single word: "спасибо большое" repeated six times
    is the same failure and used to be accepted at high confidence, because only
    identical consecutive unigrams were checked. Phrases up to `longest` words
    are now checked, and a run counts when it repeats at least three times AND
    covers `span` words — so "да да да" stays a plausible utterance while six
    words of anything cycling is not."""
    words = text.split()
    for size in range(1, longest + 1):
        for start in range(len(words)):
            phrase = words[start : start + size]
            if len(phrase) < size:
                break
            repeats = 1
            while words[start + repeats * size : start + (repeats + 1) * size] == phrase:
                repeats += 1
            if repeats >= 3 and repeats * size >= span:
                return True
    return False

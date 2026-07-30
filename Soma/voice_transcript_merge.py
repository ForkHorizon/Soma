#!/usr/bin/env python3
"""Stitching chunk transcripts back into one, and spotting decoder loops.

Pure text functions with no server state. Chunks are cut at pauses, or forced
after a long unbroken stretch — a forced cut replays ~750ms of audio, so the two
transcripts overlap and have to be joined on a matching word run.
"""
from __future__ import annotations

import re

MAX_OVERLAP_WORDS = 16
MAX_REPEATED_UNIT_WORDS = 8
MIN_PUNCTUATION_RUN = 8


def normalized_word(word: str) -> str:
    return re.sub(r"[^\w]+", "", word, flags=re.UNICODE).casefold()


def join_overlap(existing: str, incoming: str) -> tuple[str, bool]:
    """Join on the longest matching word run. The flag is False when no overlap
    matched, which means the seam is a guess rather than a known join."""
    left = existing.split()
    right = incoming.split()
    max_overlap = min(len(left), len(right), MAX_OVERLAP_WORDS)
    for count in range(max_overlap, 0, -1):
        if [normalized_word(word) for word in left[-count:]] == [normalized_word(word) for word in right[:count]]:
            return " ".join(left + right[count:]).strip(), True
    return f"{existing} {incoming}".strip(), False


def strip_context_prefix(context: str, incoming: str) -> tuple[str, bool]:
    """Drop a replayed context chunk's transcript from the front of `incoming`."""
    context_words = context.split()
    incoming_words = incoming.split()
    if not context_words:
        return incoming, True
    count = len(context_words)
    if len(incoming_words) <= count:
        return incoming, False
    if [normalized_word(word) for word in incoming_words[:count]] != [normalized_word(word) for word in context_words]:
        return incoming, False
    return " ".join(incoming_words[count:]).strip(), True


def has_pathological_repetition(text: str) -> bool:
    if _has_punctuation_run(text):
        return True
    words = [normalized_word(word) for word in text.split()]
    words = [word for word in words if word]
    # Decoder loops can alternate between words or repeat a short phrase.
    # Detect a unit of up to eight words repeated at least three times.
    for unit_length in range(1, min(MAX_REPEATED_UNIT_WORDS, len(words) // 3) + 1):
        minimum_length = max(12, unit_length * 3)
        for start in range(0, len(words) - minimum_length + 1):
            if all(words[start + offset] == words[start + offset % unit_length] for offset in range(unit_length, minimum_length)):
                return True
    return False


def _has_punctuation_run(text: str) -> bool:
    punctuation_run = 0
    previous_punctuation = ""
    for raw_word in text.split():
        word = normalized_word(raw_word)
        punctuation = "".join(character for character in raw_word if not character.isalnum())
        if not word and punctuation:
            punctuation_run = punctuation_run + 1 if punctuation == previous_punctuation else 1
            if punctuation_run >= MIN_PUNCTUATION_RUN:
                return True
        else:
            punctuation_run = 0
        previous_punctuation = punctuation
    return False

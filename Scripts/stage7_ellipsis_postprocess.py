#!/usr/bin/env python3
"""Stage-7 experimental punctuation and personal hallucination filters.

This is intentionally NOT part of word-level evaluation and does not rewrite
any gold. It removes an ASR-inserted ellipsis only when it ends a fragment
before whitespace/end of transcript; review changes remain the acceptance set.
"""
import re

PLANNING_ELLIPSIS = re.compile(r"\.\.\.(?=\s|$)")
# User-specific, human-audited hallucination: it never occurs in their speech.
# It may be a whole silent-file transcript or an appended tail after real text.
CONTINUED_CREDITS = re.compile(r"\s*продолжение\s+следует\s*(?:\.\.\.)?", re.IGNORECASE)
SUBTITLE_CREDITS = re.compile(r"\s*субтитры\s+сделал(?:и)?(?:\s+(?:dimatorzok|диматорзок))?\s*(?:\.\.\.)?", re.IGNORECASE)


def remove_planning_ellipsis(text: str) -> str:
    return PLANNING_ELLIPSIS.sub("", text)


def strip_continued_credits(text: str) -> str:
    """Remove the known hallucinated credit without dropping preceding speech."""
    return CONTINUED_CREDITS.sub("", text).strip()


def strip_personal_credits(text: str) -> str:
    """Remove either user-confirmed hallucinated credits phrase."""
    return SUBTITLE_CREDITS.sub("", strip_continued_credits(text)).strip()


def compare(proposed: str, audited: str) -> bool:
    """Whether this narrow rule exactly explains a human punctuation change."""
    return remove_planning_ellipsis(proposed) == audited

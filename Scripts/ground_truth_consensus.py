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

import math

from ground_truth_text import (Glossary, agrees, cross_script,   # noqa: F401
                               normalize, proposed_terms, repeats_itself,
                               same_word, unforgiven_edits, wer)

# Votes are grouped by what they actually share, because agreement inside a
# family proves much less than agreement across one.
#
# The Whisper family is six readings of ONE acoustic model — fw-beam included,
# since faster-whisper runs the same large-v3 weights through a different
# decoder (the only one here that implements beam search at all). Six correlated
# opinions are not six votes.
#
# The GigaAM family is two heads on one encoder: RNNT and CTC. Also correlated
# with each other, but independent of Whisper in weights and training data —
# which is the only reason anything can be accepted automatically.
PRIMARY = "w-greedy"
GIGAAM = "gigaam"
WHISPER_CONFIGS = (PRIMARY, "w-prompt", "w-fallback", "w-sample", "w-offset", "fw-beam")
GIGAAM_CONFIGS = (GIGAAM, "gigaam-ctc")

def _verdict(status: str, text: str, reason: str, **extra) -> dict:
    return {"status": status, "text": text, "reason": reason, **extra}


# Set at the LOWEST hallucination actually measured (0.851, 0.88) rather than
# halfway to the one speech reading (0.020). Between 0.8 and 0.02 there is no
# data, and inventing a threshold there would be guessing about an irreversible
# discard, so files in that gap go to a human.
NO_SPEECH_PROB = 0.8


def decide(candidates: dict[str, str | None], glossary: Glossary | None = None,
           metrics: dict | None = None) -> dict:
    """candidates maps config name -> transcript, or None if that decode failed.
    metrics carries Whisper's own no_speech/peak_db readings for the file.

    Returns a verdict dict with status accepted / review / empty / error.
    """
    heads = [n for n in GIGAAM_CONFIGS if candidates.get(n) is not None]
    if candidates.get(PRIMARY) is None or not heads:
        missing = [PRIMARY] if candidates.get(PRIMARY) is None else []
        missing += [] if heads else ["every gigaam head"]
        return _verdict("error", "", f"no usable decode from: {', '.join(missing)}")

    norm = {name: normalize(text) for name, text in candidates.items() if text is not None}
    silent = _hallucinated_over_silence(norm, metrics or {})
    if silent:
        return silent
    if not any(norm.values()):
        # Whisper reporting speech while returning no text is an anomaly worth
        # a listen, not a discard justified by the blank output itself.
        return _verdict("review", "", "every engine returned nothing, but the no-speech evidence does not support it",
                        candidates=candidates, wer=1.0, edits=0, terms=[])
    return _adjudicate(candidates, norm, glossary)


def _hallucinated_over_silence(norm: dict[str, str], metrics: dict) -> dict | None:
    """Whisper answers silence with a stock phrase — "Спасибо", "Продолжение
    следует" — and reports no_speech_prob per segment while doing it. Requiring
    GigaAM's independent silence too means two architectures must agree that
    nothing was said. Transcript length is not evidence: a genuine "да" is short.

    A discard cannot be undone from the panel, so every uncertain input fails
    CLOSED, to a human: a missing reading, a NaN, or a probability under the
    measured hallucination floor. The waveform level is reported but is NOT a
    gate — real silent recordings here peak at -20 to -29 dBFS, so any threshold
    on it would be invented."""
    if any(norm.get(name) for name in GIGAAM_CONFIGS):
        return None
    no_speech, peak = metrics.get("no_speech"), metrics.get("peak_db")
    if not isinstance(no_speech, (int, float)) or not math.isfinite(no_speech):
        return None
    if no_speech < NO_SPEECH_PROB:
        return None
    level = f", peak {peak:.0f} dBFS" if isinstance(peak, (int, float)) and math.isfinite(peak) else ""
    return _verdict("empty", "", f"whisper no_speech={no_speech:.2f}, gigaam heard nothing{level}")


def _adjudicate(candidates: dict[str, str | None], norm: dict[str, str],
                glossary: Glossary | None) -> dict:
    """Pick whichever GigaAM head draws the most Whisper agreement and judge
    against that — asking the weaker head to carry the verdict would reject
    files the stronger one settles."""
    russian = [name for name in GIGAAM_CONFIGS if name in norm]
    tried = [name for name in WHISPER_CONFIGS if name in norm]
    scored = [(len([w for w in tried if agrees(norm[name], norm[w], glossary)]), name)
              for name in russian]
    votes, best_russian = max(scored)
    deadlock = _deadlocked_heads(scored, norm, candidates, glossary)
    if deadlock:
        return deadlock
    reference = norm[best_russian]
    agreeing = [name for name in tried if agrees(reference, norm[name], glossary)]
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
                        candidates=candidates, wer=round(closest[0], 4), edits=edits, terms=terms,
                        span=_disputed_span(candidates, reference, PRIMARY, glossary))

    text = candidates[agreeing[0]] or ""
    if repeats_itself(norm[agreeing[0]]):
        return _verdict("review", "", "engines agree on a repeated-token loop, which reads as a hallucination",
                        candidates=candidates, wer=0.0, edits=0)
    # Both GigaAM heads landing on the same text is the strongest signal
    # available: two decoders, one encoder, and a whole separate architecture
    # from every Whisper vote. A dissenting head always costs the high grade,
    # even when every Whisper decode agrees — it is the only vote that can.
    heads = len([name for name in russian if agrees(reference, norm[name], glossary)])
    exact = agreeing[0] == PRIMARY and len(agreeing) == len(tried) and heads == len(russian)
    if len(agreeing) < 2 and not exact:
        return _verdict("review", "", f"only {agreeing[0]} matches {best_russian}; the other whisper decodes disagree",
                        candidates=candidates, wer=round(closest[0], 4), edits=edits, terms=terms,
                        span=_disputed_span(candidates, reference, PRIMARY, glossary))
    strong = exact or (len(agreeing) >= 3 and heads == len(russian))
    return _verdict("accepted", text,
                    f"{best_russian} matches {len(agreeing)}/{len(tried)} whisper decodes "
                    f"({', '.join(agreeing)}); {heads}/{len(russian)} gigaam head(s) agree",
                    confidence="high" if strong else "medium", wer=0.0, votes=votes)


def _deadlocked_heads(scored: list[tuple[int, str]], norm: dict[str, str],
                      candidates: dict[str, str | None], glossary: Glossary | None) -> dict | None:
    """A review verdict when the GigaAM heads read the recording differently and
    pull the same non-zero number of Whisper decodes each; None otherwise.

    Otherwise `max()` breaks that tie on the config NAME — "gigaam-ctc" wins
    over "gigaam" by string comparison — and accepts whichever text the
    alphabet picked. An even split of the only independent evidence is the
    exact case this design exists to hand to a person.

    Two ties need no handling: zero-zero (a review anyway, since neither head
    has Whisper support) and heads that tie while agreeing on the text."""
    top = max(score for score, _ in scored)
    tied = [name for score, name in scored if score == top]
    if top == 0 or len(tied) < 2:
        return None
    if all(agrees(norm[tied[0]], norm[other], glossary) for other in tied[1:]):
        return None
    return _verdict("review", "",
                    f"the two gigaam heads read this differently and draw {top} whisper "
                    f"decode(s) each — the independent evidence is split, so a human decides",
                    candidates=candidates, wer=1.0, edits=top, terms=[],
                    span=_disputed_span(candidates, norm[GIGAAM], PRIMARY, glossary))


def _disputed_span(candidates: dict[str, str | None], reference: str,
                   closest: str, glossary: Glossary | None) -> list[float] | None:
    """Word index range of the disagreement in the closest Whisper decode.

    One wrong word in a two-minute recording currently costs a full listen. The
    orchestrator turns these indices into seconds using the tier-one word
    timestamps, so the panel can play just the seconds in question."""
    import difflib

    hypothesis = normalize(candidates.get(closest) or "").split()
    reference_words = reference.split()
    marks = [j for tag, i1, i2, j1, j2 in
             difflib.SequenceMatcher(a=reference_words, b=hypothesis).get_opcodes()
             if tag != "equal"
             for j in range(j1, max(j2, j1 + 1))]
    unforgiven = [j for j in marks if j >= len(hypothesis)
                  or not any(same_word(r, hypothesis[j], glossary) for r in reference_words)]
    interesting = unforgiven or marks
    if not interesting:
        return None
    return [float(min(interesting)), float(max(interesting))]


def needs_second_tier(candidates: dict[str, str | None], glossary: Glossary | None = None) -> bool:
    """After the cheap pass (w-greedy + gigaam), does this file justify paying
    for the three extra Whisper decodes? Only a disagreement does."""
    primary, russian = candidates.get(PRIMARY), candidates.get(GIGAAM)
    if primary is None or russian is None:
        return False
    return not agrees(normalize(russian), normalize(primary), glossary)

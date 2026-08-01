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
    heads = [n for n in GIGAAM_CONFIGS if candidates.get(n) is not None]
    if candidates.get(PRIMARY) is None or not heads:
        missing = [PRIMARY] if candidates.get(PRIMARY) is None else []
        missing += [] if heads else ["every gigaam head"]
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
    if any(norm.get(name) for name in GIGAAM_CONFIGS):
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

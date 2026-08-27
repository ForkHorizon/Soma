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

import difflib
import hashlib
import math

from ground_truth_text import (Glossary, agrees, canonical_numbers,   # noqa: F401
                               cross_script, normalize, proposed_terms,
                               repeats_itself, same_word, unforgiven_edits, wer)

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
                        **review_details(candidates, glossary))

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
                        **review_details(candidates, glossary))
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
                    **review_details(candidates, glossary))


def _token_map(text: str) -> tuple[list[str], list[int], list[str]]:
    """Normalised comparison tokens, their owning raw word, and raw words.

    A raw token can expand while normalising (``api/sdk`` for example).  Keeping
    this mapping makes a review operation point at the word carrying the
    timestamp instead of applying normalised indices directly to raw timings.
    """
    raw = text.split()
    tokens, owners = [], []
    for index, word in enumerate(raw):
        for token in normalize(word).split():
            tokens.append(token)
            owners.append(index)
    return tokens, owners, raw


def _boundary(owners: list[int], raw: list[str], index: int) -> int:
    if index <= 0:
        return 0
    if index >= len(owners):
        return len(raw)
    return owners[index]


def _settled_key(text: str, glossary: Glossary | None) -> str:
    """What two spellings must share before they stop being a question.

    Two things are folded here that the raw diff still reported as
    disagreement even after the vote had stopped counting them: spelled-out
    numerals, and the cross-script pairs the listener has confirmed by ear.
    Confirming "ишью -> issue" once therefore removes that spot from every
    later recording, which is the only way a single decision generalises.

    Nothing is folded by alphabet alone. An unconfirmed "аудио" against "audi"
    stays two options, because guessing there would bury a real mishearing
    under a spelling convention."""
    written = {spelling: heard for heard, spellings in (glossary or {}).items()
               for spelling in spellings}
    words = canonical_numbers(normalize(text).split())
    return " ".join(written.get(word, word) for word in words)


def _worth_asking(options: list[dict], primary_local: str,
                  glossary: Glossary | None) -> list[dict] | None:
    """Prune an operation's readings to the ones a person should adjudicate,
    or None when nobody needs to look at it.

    A reading carried by a single Whisper decode out of seven is that decode's
    own noise — w-sample perturbs the temperature and w-offset shifts the window
    precisely so they can wander. Asking a human to rule on a lone wanderer
    cost a third of the queue.

    A lone GIGAAM reading is a different matter. It comes from the only
    architecture here that shares neither weights nor training data with the
    Whisper family, and the Whisper floor counts six correlated decodes of one
    model as six votes while a dissenting GigaAM head counts as zero — so a
    "whisper unanimous but gigaam dissents" file lost every operation and fell
    through to a whole-transcript fallback card (30 files at the time this was
    written). A cross-architecture dissent is exactly what the panel exists to
    surface, so it survives with a single name attached.

    A spot where EVERY decode differs keeps all of its options: that is a real
    seven-way split, not noise."""
    def is_cross_architecture(option: dict) -> bool:
        return any(name in GIGAAM_CONFIGS for name in option["names"])

    supported = [option for option in options
                 if len(option["names"]) >= 2 or is_cross_architecture(option)]
    if supported:
        options = supported
    if len(options) > 1:
        return options
    # One reading survived. If it is what the primary transcript already says
    # there is nothing to apply; otherwise it is kept as the sole alternative
    # so the majority correction still lands in the reference unattended.
    if not options or _settled_key(options[0]["text"], glossary) == _settled_key(primary_local, glossary):
        return None
    return options


def review_operations(candidates: dict[str, str | None], glossary: Glossary | None = None) -> list[dict]:
    """Independent, non-overlap-merged replacements in the primary transcript.

    The old set-of-indices algorithm forgot which edit created an index and then
    joined differences merely because they were nearby.  Here each opcode keeps
    its candidate span.  Only genuinely overlapping anchor spans become one
    operation, which is the minimum needed for choices to be independently
    applicable when the final reference is assembled.
    """
    primary_text = candidates.get(PRIMARY) or ""
    primary, owners, raw_primary = _token_map(primary_text)
    if not primary:
        return []
    changes = []
    for name, text in candidates.items():
        if name == PRIMARY or text is None:
            continue
        other, other_owners, raw_other = _token_map(text)
        for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(a=primary, b=other).get_opcodes():
            if tag == "equal":
                continue
            changes.append({"start": _boundary(owners, raw_primary, i1),
                            "end": _boundary(owners, raw_primary, i2),
                            "name": name,
                            "other_start": _boundary(other_owners, raw_other, j1),
                            "other_end": _boundary(other_owners, raw_other, j2),
                            "other_raw": raw_other})
    if not changes:
        return []
    changes.sort(key=lambda change: (change["start"], change["end"], change["name"]))
    groups: list[list[dict]] = []
    for change in changes:
        if groups and change["start"] <= max(item["end"] for item in groups[-1]):
            groups[-1].append(change)
        else:
            groups.append([change])
    operations = []
    for group in groups:
        start = min(item["start"] for item in group)
        end = max(item["end"] for item in group)
        by_name = {item["name"]: item for item in group}
        # A decoder that diverges for a whole sentence has no safe semantic
        # alignment point.  Do not make the listener choose it in one 30-second
        # action: split at punctuation, otherwise at four anchor words.  The
        # alternative slice follows the same fraction of that decoder's change;
        # the UI labels these as ordinary local alternatives, not a fabricated
        # timestamp from the other engine.
        parts, cursor = ([(start, end)] if start == end else []), start
        while cursor < end:
            limit = min(end, cursor + 4)
            punctuated = [index + 1 for index in range(cursor, limit)
                           if raw_primary[index].endswith((".", ",", "!", "?", ";", ":"))]
            part_end = punctuated[-1] if punctuated else limit
            parts.append((cursor, part_end))
            cursor = part_end
        for part_start, part_end in parts:
            variants: dict[str, dict] = {}
            for name, text in candidates.items():
                if text is None:
                    continue
                change = by_name.get(name)
                if change is None:
                    local = " ".join(raw_primary[part_start:part_end])
                elif change["start"] == change["end"]:
                    local = " ".join(change["other_raw"][change["other_start"]:change["other_end"]])
                else:
                    width = max(1, change["end"] - change["start"])
                    other_width = change["other_end"] - change["other_start"]
                    left = change["other_start"] + round((part_start - change["start"]) * other_width / width)
                    right = change["other_start"] + round((part_end - change["start"]) * other_width / width)
                    local = " ".join(change["other_raw"][left:right])
                key = _settled_key(local, glossary)
                variant = variants.setdefault(key, {"names": [], "text": local})
                if same_word(normalize(variant["text"]), normalize(local), glossary):
                    # The confirmed pair collapsed two spellings into one option,
                    # so the option must carry the spelling that was confirmed —
                    # "issue", not the "ишью" GigaAM happened to emit first.
                    variant["text"] = local
                variant["names"].append(name)
            options = _worth_asking(list(variants.values()),
                                    " ".join(raw_primary[part_start:part_end]), glossary)
            if options is None:
                continue
            fingerprint = "\x1f".join([str(part_start), str(part_end)] + ["+".join(option["names"]) + ":" + option["text"] for option in options])
            operations.append({"id": f"{part_start}:{part_end}",
                               "signature": hashlib.sha256(fingerprint.encode()).hexdigest()[:16],
                               "anchor": [part_start, part_end],
                               "context": [" ".join(raw_primary[max(0, part_start - 3):part_start]),
                                           " ".join(raw_primary[part_end:part_end + 3])],
                               "alternatives": options})
    return operations


def review_details(candidates: dict[str, str | None], glossary: Glossary | None) -> dict:
    operations = review_operations(candidates, glossary)
    # Kept for old verdict consumers and tests. New clients use the operation
    # schema, whose half-open anchor span also represents insertions.
    spots = [[operation["anchor"][0], max(operation["anchor"][0], operation["anchor"][1] - 1)]
             for operation in operations]
    return {"review_operations": operations, "spots": spots}


def disputed_spots(candidates: dict[str, str | None], glossary: Glossary | None) -> list[list[int]]:
    return review_details(candidates, glossary)["spots"]


def needs_second_tier(candidates: dict[str, str | None], glossary: Glossary | None = None) -> bool:
    """After the cheap pass (w-greedy + gigaam), does this file justify paying
    for the three extra Whisper decodes? Only a disagreement does."""
    primary, russian = candidates.get(PRIMARY), candidates.get(GIGAAM)
    if primary is None or russian is None:
        return False
    return not agrees(normalize(russian), normalize(primary), glossary)

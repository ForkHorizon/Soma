# Review Redesign: Session Mode + Cross-Architecture Floor

Date: 2026-08-20. Answers the listener's complaint: the old review panel was
unusable — walls of text, files with no correct option and no way to edit.

## What was wrong (measured)

1. **30 "monster" files** — whole transcripts shown as alternatives. Root
   cause was not UI: `_worth_asking` required ≥2 decodes per reading, so when
   all six Whisper decodes (one acoustic model, correlated) agreed and each
   GigaAM head dissented alone, EVERY operation was pruned, the verdict had
   `review_operations: []`, and the Swift fallback offered entire candidate
   transcripts (up to 378 chars) as "options".
2. **No way to fix what no engine disputed.** Gold was assembled by patching
   `w-greedy` at operation anchors only. If every engine misheard the same
   word, that error was structurally invisible — you could not correct it.
3. **No session shape.** An expanding list of 150 rows rewards long sittings
   and punishes the five-minute visits that actually fit a day.

## Fixes

### Cross-architecture floor (Scripts/ground_truth_consensus.py)

`_worth_asking` now keeps a reading if it has ≥2 supporting decodes **or is
carried by a GigaAM head**. A lone Whisper decode is still noise (w-sample
wanders by design); a lone GigaAM reading is the only independent evidence in
the system and must reach a human.

Verified on the live corpus after `--adjudicate-only` re-vote (backup kept at
`verdicts.pre-vetov2-revote.jsonl`):

| metric | before | after |
|---|---|---|
| monster files | 30 | 0 |
| pending review files | 477 | 477 (all now with real operations) |
| shown decisions | 2 394 | 2 873 |
| median listening per file | 14 s | 17 s |

### Session mode (Soma/Views/GroundTruthReviewSession.swift)

One disputed spot per screen, autoplay on open, keys 1–9 pick a reading,
Space replays, Esc skips, the text field takes "none of these are right"
answers. A session timer (default 5 min) ends with a summary; every decision
is appended to `review_progress.jsonl` the moment it is made, so closing the
window loses nothing. Decisions already on disk are carried over — a file
half-finished last week resumes where it stopped.

### Final edit before gold

When a file's last shown decision is made, the assembled transcript appears
in an editor for one last pass, then goes to `gold.jsonl` with
`source: "review-session"`. This is where you fix what no engine disputed,
and where filler words are kept or dropped (see policy below).
`GroundTruthGold.assemble` (the pure function that computes the text) is now
separate from `settle` and covered by `Scripts/check_assemble.swift`
(8 checks: undecided blocks, majority auto-apply, recorded choice wins,
anchors hold, insertion, deletion, out-of-range fails closed, mixed ops).

## Filler / repeat policy (what goes into gold)

**Verbatim: write exactly what was said — including «а», «э», «мм», repeated
words, and "wrong" grammatical forms that were actually spoken.**

Rationale:

- Gold exists to score ASR. If you clean the hesitations out of the reference
  but the model (correctly) transcribes them, every filler becomes a phantom
  error; if you clean gold AND the model skips them too, the metric silently
  rewards deleting real speech. Either way the number lies.
- Whisper already under-produces Russian fillers. Verbatim gold is the only
  thing that makes that failure visible and fixable.
- The wrong-but-spoken form («смотри» where grammar wants «смотрю») is data,
  not noise: the model should learn to output what the mouth said.

Practical rules for the final editor:

1. «А» spoken while thinking → keep it. It is speech; the timeline of the
   audio contains it.
2. A word repeated three times while searching for the next phrase → keep all
   three. Repeats-as-said is what repeats_itself (veto v2) calibrates against.
3. Whisper's own boilerplate («Продолжение следует», «Спасибо») that was NOT
   spoken → remove; that is a hallucination, not speech. GigaAM corroboration
   usually already flagged it.
4. Punctuation/case → your choice; `normalize()` and WER ignore them.

If we later want a "clean read" corpus (for TTS or prompt writing), it should
be a DERIVED view (a normalizer pass over verbatim gold), never a second
hand-maintained reference.

## File map

- `Scripts/ground_truth_consensus.py` — cross-architecture floor in
  `_worth_asking`
- `tests/test_ground_truth_consensus.py` — new tests: lone GigaAM dissent
  keeps its operation; seven-way split keeps its question (semantics updated)
- `Scripts/run_pytest_style_tests.py` — runs pytest-style modules under
  unittest (no pytest on this machine); 56/56 green
- `Soma/Views/GroundTruthReviewSession.swift` — session UI (new)
- `Soma/Views/GroundTruthView.swift` — queue button + sheet instead of list
- `Soma/Views/GroundTruthReviewView.swift` — deleted (replaced)
- `Soma/ViewModels/GroundTruthGlossary.swift` — `assemble` extracted
- `Scripts/check_assemble.swift` — pure-logic checks, `xcrun swift`-run

## Verification

- `run_pytest_style_tests.py tests/test_ground_truth_consensus.py
  tests/test_ground_truth_build.py` → 56/56
- re-vote on live corpus → 0 monsters, queue sane (table above)
- `swiftc -typecheck` whole app → 0 new errors (3 preexisting actor-isolation
  errors in `ASRManager+ImportedTranscription.swift` under the CLT SDK,
  present on the unmodified tree too)
- `check_assemble.swift` → 8/8
- linter gate `--mode changed` → 9 preexisting violations, none introduced

#!/usr/bin/env python3
"""Build a ground-truth transcript set from the saved voice recordings.

Runs under the SYSTEM python, not an engine venv: mlx-whisper, faster-whisper
and GigaAM have conflicting dependencies, so each decode pass is spawned into
its own venv and this process only orchestrates and votes.

Work is done in blocks, not whole-corpus passes, so the counters move and a
crash costs one block rather than a night. Per block: w-greedy over the whole
block, GigaAM RNNT over the same files, then six more decodes only where those
two disagree (unless --thorough), then vote across families.

Resumable: every decode and verdict is appended to disk and a rerun skips files
that already have a verdict. Because a verdict is FINAL, it is only written once
every required engine has actually had its turn — see Runner.can_settle. One
run owns an output directory at a time; see claim_lock.
"""
from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ground_truth_consensus import needs_second_tier   # noqa: E402
from ground_truth_corpus import (claim_lock, has_audio, pick,   # noqa: E402
                                 read_rows, release_lock, replace_atomically)
from ground_truth_runner import (TIER_ONE, TIER_TWO, TIER_TWO_FASTER,   # noqa: E402
                                 TIER_TWO_GIGAAM, Runner, emit)

DEFAULT_RECORDINGS = Path.home() / "Library/Application Support/Soma/VoiceRecordings"



def totals(runner: Runner, total_files: int) -> dict:
    counts: dict[str, int] = {"accepted": 0, "review": 0, "error": 0, "empty": 0}
    for record in runner.done.values():
        counts[record["status"]] = counts.get(record["status"], 0) + 1
    return {"event": "totals", "files": total_files, "decided": len(runner.done), **counts}




def run_block(runner: Runner, block: list[Path], thorough: bool = False) -> None:
    runner.decode("whisper", TIER_ONE, block)
    runner.decode("gigaam", "gigaam", block)
    # Thorough spends the remaining six decodes on files the cheap pass already
    # agreed on. It cannot overturn those verdicts — agreement across families
    # still decides — but it grades them: a file every engine settles on is a
    # different thing from one where only the first two happened to match.
    disputed = block if thorough else [
        p for p in block
        if needs_second_tier(runner.candidates(p.name, [TIER_ONE, "gigaam"]), runner.glossary)]
    if disputed:
        headline = "all" if thorough else f"{len(disputed)} disagreed —"
        emit({"event": "stage", "text": f"{headline} {len(disputed)} recordings: six more decodes each"})
        runner.decode("whisper", TIER_TWO, disputed)
        runner.decode("fasterwhisper", TIER_TWO_FASTER, disputed)
        runner.decode("gigaam", TIER_TWO_GIGAAM, disputed)
    for path in block:
        runner.settle(path)


def readjudicate(runner: Runner, files: list[Path]) -> int:
    """Recompute every verdict from decodes already on disk, under the current
    glossary. Verdicts are rewritten wholesale because a term confirmed today
    can flip a file decided yesterday — but only swapped in once the new set is
    complete on disk, so an interrupted re-vote cannot leave a corpus shorter
    than it started."""
    previous = read_rows(runner.verdicts)
    runner.done.clear()
    decided = [p for p in files if (p.name, PRIMARY) in runner.decoded]
    emit({"event": "plan", "files": len(files), "pending": 0, "blocks": 0,
          "tier_one": TIER_ONE,
          "tier_two": ",".join([TIER_TWO, TIER_TWO_FASTER, TIER_TWO_GIGAAM])})
    emit({"event": "stage", "text": f"Re-voting {len(decided)} decoded recordings under the glossary"})
    rebuilt = [runner.settle(path, publish=False) for path in decided]
    rows = [row for row in rebuilt if row]
    if not rows and previous:
        emit({"event": "warn", "text": "re-vote produced nothing; keeping the previous verdicts"})
        runner.done = {row["file"]: row for row in previous}
        return 1
    replace_atomically(runner.verdicts, rows)
    emit({"event": "done", **totals(runner, len(files))})
    return 0


def hold_awake() -> None:
    """Keep the machine up for exactly as long as this run lasts.

    The point of the panel is a job left running overnight, and on battery this
    Mac sleeps after a minute. `caffeinate -w` waits on our PID, so the
    assertion is owned by the run and released the moment it ends — no leftover
    assertion outliving the work, and nothing to remember to switch off."""
    try:
        subprocess.Popen(["/usr/bin/caffeinate", "-i", "-w", str(os.getpid())],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as error:
        emit({"event": "warn", "text": f"could not hold the machine awake: {error}"})


def parse(argv: list[str] | None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recordings", type=Path, default=DEFAULT_RECORDINGS)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--engines-root", type=Path, required=True)
    parser.add_argument("--models-root", type=Path, required=True)
    parser.add_argument("--block", type=int, default=40)
    # The one honest "more compute per file" knob: a temperature-0 decode
    # repeats byte-identically, sampling N and ranking does not.
    parser.add_argument("--best-of", type=int, default=5)
    parser.add_argument("--limit", type=int, default=0, help="0 means the whole corpus")
    # Re-vote from cached decodes after the glossary grew: seconds, no model
    # time, which is why every decode stays on disk.
    parser.add_argument("--adjudicate-only", action="store_true")
    # Every engine on every recording, not just disagreements: turns "these two
    # agreed" into "nothing available disagrees".
    parser.add_argument("--thorough", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse(argv)
    runner = Runner(args)
    hold_awake()
    for received in (signal.SIGTERM, signal.SIGINT):
        signal.signal(received, runner.stop_worker)
    lock = args.out / "run.lock"
    if not claim_lock(lock):
        emit({"event": "fatal", "config": "orchestrator",
              "error": f"another run already owns {args.out}"})
        return 2
    try:
        return _run(runner, args, files=pick(args.recordings, args.limit))
    finally:
        release_lock(lock)


def _run(runner: Runner, args, files: list[Path]) -> int:
    if args.adjudicate_only:
        return readjudicate(runner, files)
    for path in [p for p in files if p.name not in runner.done and not has_audio(p)]:
        runner.write(path, {"status": "empty", "text": "",
                            "reason": "recording contains no audio (zero frames)"})
    # An error verdict is a report of a failure, not a decision about the
    # recording, so it must not retire the file the way a real verdict does. A
    # rerun retries it; a permanently broken file simply fails again, visibly.
    pending = [p for p in files
               if (runner.done.get(p.name) or {}).get("status", "error") == "error"]
    blocks = [pending[i:i + args.block] for i in range(0, len(pending), args.block)]
    emit({"event": "plan", "files": len(files), "pending": len(pending), "blocks": len(blocks),
          "tier_one": TIER_ONE,
          "tier_two": ",".join([TIER_TWO, TIER_TWO_FASTER, TIER_TWO_GIGAAM])})
    emit(totals(runner, len(files)))

    for index, block in enumerate(blocks, start=1):
        emit({"event": "stage", "text": f"Block {index}/{len(blocks)} · {len(block)} recordings"})
        run_block(runner, block, args.thorough)
        emit(totals(runner, len(files)))
        if runner.fatal:
            emit({"event": "stage", "text": f"stopped: {runner.fatal}"})
            break
    emit({"event": "done", **totals(runner, len(files))})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

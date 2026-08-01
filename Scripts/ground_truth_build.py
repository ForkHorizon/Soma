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
every required engine has actually had its turn — see Runner.can_settle.

Usage:
    python3 Scripts/ground_truth_build.py --out ~/Library/.../GroundTruth
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ground_truth_consensus import PRIMARY, decide, needs_second_tier   # noqa: E402
from ground_truth_corpus import append, has_audio, pick, read_rows   # noqa: E402

TIER_ONE = "w-greedy"
# Tier two only ever runs on files where tier one disagreed, so it can afford to
# be thorough. Grouped by venv, because each spawn loads its own model.
TIER_TWO = "w-prompt,w-fallback,w-sample,w-offset"
TIER_TWO_FASTER = "fw-beam"
TIER_TWO_GIGAAM = "gigaam-ctc"
SPAN_PADDING = 1.5
DEFAULT_RECORDINGS = Path.home() / "Library/Application Support/Soma/VoiceRecordings"


def emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()



def append(path: Path, obj: dict) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(obj, ensure_ascii=False) + "\n")


class Runner:
    """Owns the output files and the spawning of engine workers."""

    def __init__(self, args) -> None:
        self.args = args
        self.results = args.out / "decodes.jsonl"
        self.verdicts = args.out / "verdicts.jsonl"
        args.out.mkdir(parents=True, exist_ok=True)
        self.decoded: dict[tuple[str, str], dict] = {
            (row["file"], row["config"]): row for row in read_rows(self.results)
        }
        self.done: dict[str, dict] = {row["file"]: row for row in read_rows(self.verdicts)}
        self.glossary = self._glossary()
        self.fatal: str | None = None

    def _glossary(self) -> dict[str, list[str]]:
        """Confirmed term pairs, written by the review panel once the listener
        has heard the audio. Absent on the first run, which is correct: nothing
        is forgiven until a human has said it may be."""
        path = self.args.out / "glossary.json"
        if not path.exists():
            return {}
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            emit({"event": "warn", "text": f"unreadable glossary at {path}"})
            return {}

    def venv_python(self, engine: str) -> Path:
        return self.args.engines_root / f"venv-{engine}" / "bin" / "python"

    def decode(self, engine: str, configs: str, paths: list[Path]) -> None:
        """Spawn one worker and fold everything it decodes into self.decoded."""
        wanted = [p for p in paths if any(
            (p.name, name) not in self.decoded for name in configs.split(","))]
        if not wanted:
            return
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8") as listing:
            listing.write("\n".join(str(p) for p in wanted))
            listing_path = listing.name
        try:
            self._spawn(engine, configs, listing_path)
        finally:
            Path(listing_path).unlink(missing_ok=True)

    def _environment(self) -> dict:
        # Set here rather than left to the caller so the same weights are used
        # whether this runs from a terminal or from the app, which inherits a
        # GUI process's minimal environment.
        environment = dict(os.environ)
        environment["HF_HOME"] = str(self.args.models_root / "hf")
        environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        return environment

    def _spawn(self, engine: str, configs: str, listing_path: str) -> None:
        command = [str(self.venv_python(engine)),
                   str(Path(__file__).resolve().parent / "ground_truth_worker.py"),
                   "--engine", engine, "--configs", configs, "--list", listing_path,
                   "--best-of", str(self.args.best_of),
                   "--gigaam-root", str(self.args.models_root / "gigaam"),
                   "--faster-root", str(self.args.models_root / "faster")]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, bufsize=1, env=self._environment())
        for line in process.stdout:
            self._consume(line, engine)
        process.wait()
        if process.returncode:
            emit({"event": "warn", "text": (process.stderr.read() or "")[-400:]})

    def _consume(self, line: str, engine: str) -> None:
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            return
        if row.get("event") == "decode":
            self.decoded[(row["file"], row["config"])] = row
            append(self.results, row)
            emit({"event": "decode", "file": row["file"], "config": row["config"],
                  "seconds": row.get("seconds"), "failed": row.get("error") is not None})
        elif row.get("event") in ("fatal", "loaded", "skip"):
            if row.get("event") == "fatal":
                # An engine that cannot load will fail identically on every
                # remaining block. Carrying on would write an error verdict for
                # the whole corpus and, because verdicts are final, bury it.
                self.fatal = f"{engine}/{row.get('config')}: {row.get('error')}"
            emit({**row, "engine": engine})

    def candidates(self, name: str, configs: list[str]) -> dict[str, str | None]:
        found = {}
        for config in configs:
            row = self.decoded.get((name, config))
            if row is not None:
                found[config] = row.get("text")
        return found

    def metrics(self, name: str) -> dict:
        """Whisper's own no_speech reading plus the waveform level, taken from
        the tier-one decode — the only pass every file is guaranteed to have."""
        row = self.decoded.get((name, PRIMARY)) or {}
        return {key: row[key] for key in ("no_speech", "peak_db", "avg_logprob") if key in row}

    def span_seconds(self, name: str, span: list | None) -> list[float] | None:
        """Turn disputed word indices into a clip the panel can play. Whisper's
        word timestamps come from the tier-one decode, so the indices are its
        own; anything out of range just widens the clip rather than dropping
        it, since a slightly long clip still beats replaying two minutes."""
        words = (self.decoded.get((name, PRIMARY)) or {}).get("words")
        if not span or not words:
            return None
        first, last = int(span[0]), int(span[1])
        first, last = max(0, min(first, len(words) - 1)), max(0, min(last, len(words) - 1))
        start = max(0.0, float(words[first][1]) - SPAN_PADDING)
        end = float(words[last][2]) + SPAN_PADDING
        return [round(start, 2), round(end, 2)] if end > start else None

    def can_settle(self, name: str) -> bool:
        """A verdict is final, so it may only be written once every engine has
        actually had its turn on this recording. A row that RAN and failed is
        fine — that is a real error. A missing row means the engine never got
        there, and settling it would bury the file forever."""
        have = [(name, config) in self.decoded for config in (TIER_ONE, "gigaam", TIER_TWO_GIGAAM)]
        return have[0] and (have[1] or have[2])

    def write(self, path: Path, verdict: dict) -> dict:
        """The single place a verdict becomes final."""
        record = {"file": path.name, **verdict}
        append(self.verdicts, record)
        self.done[path.name] = record
        emit({"event": "verdict", "file": path.name,
              "status": record["status"], "reason": record["reason"]})
        return record

    def settle(self, path: Path) -> dict | None:
        if not self.can_settle(path.name):
            emit({"event": "warn", "text": f"{path.name}: a required engine never ran; left pending"})
            return None
        every = [TIER_ONE, *TIER_TWO.split(","), TIER_TWO_FASTER, "gigaam", TIER_TWO_GIGAAM]
        verdict = decide(self.candidates(path.name, every), self.glossary, self.metrics(path.name))
        seconds = self.span_seconds(path.name, verdict.pop("span", None))
        if seconds:
            verdict["span_seconds"] = seconds
        return self.write(path, verdict)


def totals(runner: Runner, total_files: int) -> dict:
    counts = {"accepted": 0, "review": 0, "error": 0, "empty": 0}
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
    can flip a file decided yesterday."""
    runner.verdicts.write_text("", encoding="utf-8")
    runner.done.clear()
    decided = [p for p in files if (p.name, PRIMARY) in runner.decoded]
    emit({"event": "plan", "files": len(files), "pending": 0, "blocks": 0,
          "tier_one": TIER_ONE,
          "tier_two": ",".join([TIER_TWO, TIER_TWO_FASTER, TIER_TWO_GIGAAM])})
    emit({"event": "stage", "text": f"Re-voting {len(decided)} decoded recordings under the glossary"})
    for path in decided:
        runner.settle(path)
    emit({"event": "done", **totals(runner, len(files))})
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recordings", type=Path, default=DEFAULT_RECORDINGS)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--engines-root", type=Path, required=True)
    parser.add_argument("--models-root", type=Path, required=True)
    parser.add_argument("--block", type=int, default=40)
    # The one honest "spend more compute per file" knob: repeating a
    # temperature-0 decode is byte-identical, sampling N and ranking is not.
    parser.add_argument("--best-of", type=int, default=5)
    parser.add_argument("--limit", type=int, default=0, help="0 means the whole corpus")
    # Re-vote from the cached decodes after the glossary grew. Costs seconds and
    # no model time, which is the whole point of keeping every decode on disk.
    parser.add_argument("--adjudicate-only", action="store_true")
    # Every engine on every recording instead of only on disagreements. Roughly
    # 1.7x the wall clock, and it is what turns "these two agreed" into "nothing
    # available disagrees".
    parser.add_argument("--thorough", action="store_true")
    args = parser.parse_args(argv)

    runner = Runner(args)
    files = pick(args.recordings, args.limit)
    if args.adjudicate_only:
        return readjudicate(runner, files)
    for path in [p for p in files if p.name not in runner.done and not has_audio(p)]:
        runner.write(path, {"status": "empty", "text": "",
                            "reason": "recording contains no audio (zero frames)"})
    pending = [p for p in files if p.name not in runner.done]
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

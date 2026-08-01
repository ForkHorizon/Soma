#!/usr/bin/env python3
"""Build a ground-truth transcript set from the saved voice recordings.

Runs under the SYSTEM python, not an engine venv: the two engines have
conflicting dependencies, so each decode pass is spawned into its own venv and
this process only orchestrates and votes.

Work is done in blocks rather than whole-corpus passes so the counters move and
a crash costs one block, not a night. Per block:

    1. Whisper w-greedy over every file in the block
    2. GigaAM v2 over the same files            <- the independent vote
    3. files where the two disagree get three more Whisper decodes
    4. vote, write verdicts

Resumable: every decode and every verdict is appended to disk, and a rerun skips
the files that already have a verdict.

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

TIER_ONE = "w-greedy"
TIER_TWO = "w-prompt,w-fallback,w-sample"
DEFAULT_RECORDINGS = Path.home() / "Library/Application Support/Soma/VoiceRecordings"


def emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def read_rows(path: Path) -> list[dict]:
    if not path.exists():
        return []
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue          # a half-written last line after a kill, not a reason to stop
    return rows


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
                   "--gigaam-root", str(self.args.models_root / "gigaam")]
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
        elif row.get("event") in ("fatal", "loaded"):
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

    def settle(self, path: Path) -> dict:
        every = [TIER_ONE, *TIER_TWO.split(","), "gigaam"]
        verdict = decide(self.candidates(path.name, every), self.glossary, self.metrics(path.name))
        record = {"file": path.name, **verdict}
        append(self.verdicts, record)
        self.done[path.name] = record
        emit({"event": "verdict", "file": path.name,
              "status": record["status"], "reason": record["reason"]})
        return record


def totals(runner: Runner, total_files: int) -> dict:
    counts = {"accepted": 0, "review": 0, "error": 0, "empty": 0}
    for record in runner.done.values():
        counts[record["status"]] = counts.get(record["status"], 0) + 1
    return {"event": "totals", "files": total_files, "decided": len(runner.done), **counts}


def pick(recordings: Path, limit: int) -> list[Path]:
    files = sorted(recordings.glob("*.wav"), key=lambda p: p.stat().st_mtime)
    return files[:limit] if limit else files


def run_block(runner: Runner, block: list[Path]) -> None:
    runner.decode("whisper", TIER_ONE, block)
    runner.decode("gigaam", "gigaam", block)
    disputed = [p for p in block
                if needs_second_tier(runner.candidates(p.name, [TIER_ONE, "gigaam"]), runner.glossary)]
    if disputed:
        emit({"event": "stage", "text": f"{len(disputed)} disagreed — running 3 more Whisper decodes"})
        runner.decode("whisper", TIER_TWO, disputed)
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
          "tier_one": TIER_ONE, "tier_two": TIER_TWO})
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
    args = parser.parse_args(argv)

    runner = Runner(args)
    files = pick(args.recordings, args.limit)
    if args.adjudicate_only:
        return readjudicate(runner, files)
    pending = [p for p in files if p.name not in runner.done]
    blocks = [pending[i:i + args.block] for i in range(0, len(pending), args.block)]
    emit({"event": "plan", "files": len(files), "pending": len(pending), "blocks": len(blocks),
          "tier_one": TIER_ONE, "tier_two": TIER_TWO})
    emit(totals(runner, len(files)))

    for index, block in enumerate(blocks, start=1):
        emit({"event": "stage", "text": f"Block {index}/{len(blocks)} · {len(block)} recordings"})
        run_block(runner, block)
        emit(totals(runner, len(files)))
    emit({"event": "done", **totals(runner, len(files))})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

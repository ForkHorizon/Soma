#!/usr/bin/env python3
"""Owns the output files, the engine subprocesses, and when a verdict is final.

Split from the run script so that "what state a run holds" stays separate from
"what order the passes go in".
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ground_truth_consensus import PRIMARY, decide   # noqa: E402
from ground_truth_corpus import append, read_rows   # noqa: E402

TIER_ONE = "w-greedy"
# Tier two runs only where tier one disagreed. Grouped by venv: each spawn loads
# its own model.
TIER_TWO = "w-prompt,w-fallback,w-sample,w-offset"
TIER_TWO_FASTER = "fw-beam"
TIER_TWO_GIGAAM = "gigaam-ctc"
SPAN_PADDING = 1.5


def emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


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
        self.worker: subprocess.Popen | None = None
        self.noise: list[str] = []          # last non-JSON worker output, for diagnostics

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
        # Set here, not left to the caller: the app inherits a GUI process's
        # minimal environment and would otherwise use different weights.
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
        # stderr is MERGED into stdout, not given its own pipe. Draining one pipe
        # while the other fills is a deadlock waiting for a noisy night: torch
        # prints warnings and huggingface prints progress bars to stderr, so 64 KB
        # of pipe buffer fills and the child blocks forever with stdout still open.
        # Non-JSON lines are kept as diagnostics instead of being read at exit.
        self.worker = subprocess.Popen(command, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True,
                                       bufsize=1, env=self._environment())
        try:
            for line in self.worker.stdout:
                self._consume(line, engine)
            self.worker.wait()
            if self.worker.returncode:
                emit({"event": "warn",
                      "text": f"{engine} exited {self.worker.returncode}: " + " | ".join(self.noise[-4:])})
        finally:
            self.worker = None

    def stop_worker(self, *_) -> None:
        """Forward a stop to the model process. Terminating only the orchestrator
        leaves a loaded Whisper or GigaAM decoding against a UI that says
        Stopped, holding the memory a restarted run needs."""
        worker = self.worker
        if worker and worker.poll() is None:
            worker.terminate()
            try:
                worker.wait(timeout=10)
            except subprocess.TimeoutExpired:
                worker.kill()
        sys.exit(143)

    def _consume(self, line: str, engine: str) -> None:
        row = self._parse(line, engine)
        if row is None:
            return
        if row.get("event") == "decode":
            self.decoded[(row["file"], row["config"])] = row
            append(self.results, row)
            emit({"event": "decode", "file": row["file"], "config": row["config"],
                  "seconds": row.get("seconds"), "failed": row.get("error") is not None})
        elif row.get("event") in ("fatal", "loaded", "skip"):
            if row.get("event") == "fatal":
                # An engine that cannot load fails identically on every
                # remaining block; carrying on would bury the whole corpus.
                self.fatal = f"{engine}/{row.get('config')}: {row.get('error')}"
            emit({**row, "engine": engine})

    def _parse(self, line: str, engine: str) -> dict | None:
        """Recover the event even when engine noise shares its line.

        Merging stderr into stdout cures the pipe deadlock but means a flood
        with no trailing newline — a tqdm bar redraws with \r, not \n — arrives
        fused to the event that follows it. Retrying from the last opening brace
        costs nothing and stops a progress bar from hiding a `fatal`."""
        for candidate in (line, line[line.rfind("{"):] if "{" in line else ""):
            try:
                parsed = json.loads(candidate)
            except (json.JSONDecodeError, ValueError):
                continue
            if isinstance(parsed, dict):
                return parsed
        text = line.strip()
        if text:
            self.noise = (self.noise + [text[:200]])[-20:]
        return None

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
        """Turn disputed word indices into a clip the panel can play. Indices
        are the tier-one decode's own; out-of-range ones widen the clip rather
        than drop it, since a long clip still beats replaying two minutes."""
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

    def write(self, path: Path, verdict: dict, publish: bool = True) -> dict:
        """The single place a verdict becomes final."""
        record = {"file": path.name, **verdict}
        if publish:
            append(self.verdicts, record)
        self.done[path.name] = record
        emit({"event": "verdict", "file": path.name,
              "status": record["status"], "reason": record["reason"]})
        return record

    def settle(self, path: Path, publish: bool = True) -> dict | None:
        """publish=False computes and remembers the verdict without appending it,
        so a full re-vote can be swapped in atomically once it is complete."""
        if not self.can_settle(path.name):
            emit({"event": "warn", "text": f"{path.name}: a required engine never ran; left pending"})
            return None
        every = [TIER_ONE, *TIER_TWO.split(","), TIER_TWO_FASTER, "gigaam", TIER_TWO_GIGAAM]
        verdict = decide(self.candidates(path.name, every), self.glossary, self.metrics(path.name))
        seconds = self.span_seconds(path.name, verdict.pop("span", None))
        if seconds:
            verdict["span_seconds"] = seconds
        return self.write(path, verdict, publish)



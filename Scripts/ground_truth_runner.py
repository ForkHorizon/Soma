#!/usr/bin/env python3
"""Owns the output files, the engine subprocesses, and when a verdict is final.

Split from the run script so that "what state a run holds" stays separate from
"what order the passes go in".
"""

from __future__ import annotations

import json
import hashlib
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ground_truth_consensus import PRIMARY, decide  # noqa: E402
from ground_truth_corpus import append, read_rows  # noqa: E402

TIER_ONE = "w-greedy"
# Tier two runs only where tier one disagreed. Grouped by venv: each spawn loads
# its own model.
TIER_TWO = "w-prompt,w-fallback,w-sample,w-offset"
TIER_TWO_FASTER = "fw-beam"
TIER_TWO_GIGAAM = "gigaam-ctc"
SPOT_PADDING = 0.8


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
        self.noise: list[str] = []  # last non-JSON worker output, for diagnostics

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
        """Spawn one worker and fold everything it decodes into self.decoded.

        A row that recorded an ERROR is treated as absent, so a rerun actually
        re-decodes it. Keeping it would make a retry cosmetic: the file would be
        re-settled to the same failure without any engine touching it again."""
        wanted = [p for p in paths if any(self.failed_or_missing(p.name, name) for name in configs.split(","))]
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
        command = [
            str(self.venv_python(engine)),
            str(Path(__file__).resolve().parent / "ground_truth_worker.py"),
            "--engine",
            engine,
            "--configs",
            configs,
            "--list",
            listing_path,
            "--best-of",
            str(self.args.best_of),
            "--gigaam-root",
            str(self.args.models_root / "gigaam"),
            "--faster-root",
            str(self.args.models_root / "faster"),
        ]
        # stderr is MERGED into stdout, not given its own pipe. Draining one pipe
        # while the other fills is a deadlock waiting for a noisy night: torch
        # prints warnings and huggingface prints progress bars to stderr, so 64 KB
        # of pipe buffer fills and the child blocks forever with stdout still open.
        # Non-JSON lines are kept as diagnostics instead of being read at exit.
        self.worker = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, env=self._environment()
        )
        try:
            for line in self.worker.stdout:
                self._consume(line, engine)
            self.worker.wait()
            if self.worker.returncode:
                emit(
                    {
                        "event": "warn",
                        "text": f"{engine} exited {self.worker.returncode}: " + " | ".join(self.noise[-4:]),
                    }
                )
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
            emit(
                {
                    "event": "decode",
                    "file": row["file"],
                    "config": row["config"],
                    "seconds": row.get("seconds"),
                    "failed": row.get("error") is not None,
                }
            )
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
        for candidate in (line, line[line.rfind("{") :] if "{" in line else ""):
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

    def failed_or_missing(self, name: str, config: str) -> bool:
        row = self.decoded.get((name, config))
        return row is None or row.get("error") is not None

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

    def spot_seconds(self, name: str, spots: list | None) -> list[list[float]] | None:
        """Turn each disputed word cluster into its own clip.

        One range per recording could not work: disagreements scatter, so a
        single min-max either starts after the first disputed word or covers
        everything. Indices are the tier-one decode's own, the only pass with
        word timestamps; out-of-range ones widen a clip rather than drop it."""
        words = (self.decoded.get((name, PRIMARY)) or {}).get("words")
        if not spots or not words:
            return None
        clips = []
        for spot in spots:
            first = max(0, min(int(spot[0]), len(words) - 1))
            last = max(first, min(int(spot[1]), len(words) - 1))
            start = max(0.0, float(words[first][1]) - SPOT_PADDING)
            end = float(words[last][2]) + SPOT_PADDING
            if end > start:
                clips.append([round(start, 2), round(end, 2)])
        return clips or None

    def review_operation_seconds(self, name: str, operations: list[dict] | None) -> list[dict] | None:
        """Attach tier-one timing to the raw-word operations emitted by consensus."""
        words = (self.decoded.get((name, PRIMARY)) or {}).get("words")
        if not operations or not words:
            return None
        timed = []
        for operation in operations:
            anchor = operation.get("anchor") or []
            if len(anchor) != 2:
                continue
            first = max(0, min(int(anchor[0]), len(words) - 1))
            # An insertion has a zero-width anchor. Listen around the word at
            # that boundary rather than dropping a real candidate alternative.
            anchor_start, anchor_end = int(anchor[0]), int(anchor[1])
            # A slow four-word phrase can still be 20 seconds. Partition it by
            # real word timings, not a guessed words-per-second rate.
            parts = [(anchor_start, anchor_end)] if anchor_start == anchor_end else []
            cursor = anchor_start
            while cursor < anchor_end:
                part_end = cursor + 1
                while part_end < anchor_end:
                    candidate_end = min(part_end, len(words) - 1)
                    duration = (
                        float(words[candidate_end][2])
                        + SPOT_PADDING
                        - max(0.0, float(words[first if cursor == anchor_start else cursor][1]) - SPOT_PADDING)
                    )
                    if duration > 6.0:
                        break
                    part_end += 1
                parts.append((cursor, part_end))
                cursor = part_end
            for part_start, part_end in parts:
                local_first = max(0, min(part_start, len(words) - 1))
                last = max(local_first, min(max(part_start, part_end - 1), len(words) - 1))
                raw_start, raw_end = float(words[local_first][1]), float(words[last][2])
                # Preserve the normal 0.8 s context unless the spoken span
                # itself leaves less room; a slow word should not create a
                # seven-second review button solely because of padding.
                padding = min(SPOT_PADDING, max(0.0, (6.0 - (raw_end - raw_start)) / 2))
                start = max(0.0, raw_start - padding)
                end = raw_end + padding
                if end <= start:
                    continue
                fragment = {**operation, "anchor": [part_start, part_end]}
                if (part_start, part_end) != (anchor_start, anchor_end):
                    width = max(1, anchor_end - anchor_start)
                    alternatives = []
                    for option in operation.get("alternatives", []):
                        option_words = str(option.get("text", "")).split()
                        left = round((part_start - anchor_start) * len(option_words) / width)
                        right = round((part_end - anchor_start) * len(option_words) / width)
                        alternatives.append({**option, "text": " ".join(option_words[left:right])})
                    fragment["id"] = f"{operation['id']}:{part_start}:{part_end}"
                    fragment["alternatives"] = alternatives
                    fragment["signature"] = hashlib.sha256(
                        f"{operation['signature']}:{part_start}:{part_end}".encode()
                    ).hexdigest()[:16]
                fragment["seconds"] = [round(start, 2), round(end, 2)]
                timed.append(fragment)
        return timed or None

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
        emit({"event": "verdict", "file": path.name, "status": record["status"], "reason": record["reason"]})
        return record

    def settle(self, path: Path, publish: bool = True) -> dict | None:
        """publish=False computes and remembers the verdict without appending it,
        so a full re-vote can be swapped in atomically once it is complete."""
        if not self.can_settle(path.name):
            emit({"event": "warn", "text": f"{path.name}: a required engine never ran; left pending"})
            return None
        every = [TIER_ONE, *TIER_TWO.split(","), TIER_TWO_FASTER, "gigaam", TIER_TWO_GIGAAM]
        verdict = decide(self.candidates(path.name, every), self.glossary, self.metrics(path.name))
        operations = self.review_operation_seconds(path.name, verdict.pop("review_operations", None))
        if operations:
            verdict["review_operations"] = operations
        clips = self.spot_seconds(path.name, verdict.pop("spots", None))
        if clips:
            verdict["spot_seconds"] = clips
        return self.write(path, verdict, publish)

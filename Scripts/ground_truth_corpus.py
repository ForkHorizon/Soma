#!/usr/bin/env python3
"""Reading the recording corpus and the append-only result files.

Split out from the orchestrator only to keep that file under the length gate;
everything here is stdlib and side-effect free apart from the appends.
"""
from __future__ import annotations

import json
import os
import wave
from pathlib import Path


def claim_lock(path: Path) -> bool:
    """Refuse to start when another orchestrator already owns this output
    directory. Two of them appending to the same decodes.jsonl — and
    --adjudicate-only truncating verdicts.jsonl under the other's feet — would
    corrupt a night's work silently.

    A stale lock from a killed run is reclaimed: the PID inside is checked for
    life first, so a crash never needs a manual cleanup."""
    if path.exists():
        try:
            owner = int(path.read_text(encoding="utf-8").strip())
            os.kill(owner, 0)
            return False                      # a live process holds it
        except (ValueError, OSError):
            pass                              # unreadable or dead: ours to take
    path.write_text(str(os.getpid()), encoding="utf-8")
    return True


def release_lock(path: Path) -> None:
    try:
        if path.exists() and path.read_text(encoding="utf-8").strip() == str(os.getpid()):
            path.unlink()
    except OSError:
        pass


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
    """Append one object as its own line.

    A write killed mid-line leaves a tail with no newline. Appending straight
    onto it would fuse the broken record and the next good one into a single
    unparseable line, so read_rows would drop BOTH — the crash would eat a
    decode that completed after it. Closing the ragged line first costs one
    byte and confines the damage to the record that was actually interrupted."""
    ragged = path.exists() and path.stat().st_size > 0 and not path.read_bytes().endswith(b"\n")
    with path.open("a", encoding="utf-8") as handle:
        if ragged:
            handle.write("\n")
        handle.write(json.dumps(obj, ensure_ascii=False) + "\n")


def replace_atomically(path: Path, rows: list[dict]) -> None:
    """Rewrite a whole file without a window in which it does not exist.

    Truncating in place and refilling means a stop, a crash or a bad argument
    leaves a partial or empty result set where a complete one used to be."""
    scratch = path.with_suffix(path.suffix + ".new")
    with scratch.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(scratch, path)


def pick(recordings: Path, limit: int) -> list[Path]:
    files = sorted(recordings.glob("*.wav"), key=lambda p: p.stat().st_mtime)
    return files[:limit] if limit else files


def has_audio(path: Path) -> bool:
    """`wave` is stdlib, so the corpus can be screened without an engine venv.
    Aborted recordings leave a 4096-byte container with zero frames; every
    engine raises on those, which would otherwise spend two decodes to reach a
    permanent "error" verdict that is really just an empty file."""
    try:
        with wave.open(str(path)) as handle:
            return handle.getnframes() > 0
    except (wave.Error, OSError):
        return True          # unreadable header: let the engines say why

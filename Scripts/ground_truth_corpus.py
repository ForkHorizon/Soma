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
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(obj, ensure_ascii=False) + "\n")


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

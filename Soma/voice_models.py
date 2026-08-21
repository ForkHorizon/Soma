#!/usr/bin/env python3
"""Data shapes and settings persistence for Soma Voice Server.

A `Job` is one unit of ASR work. A `VoiceSession` groups the ordered chunks of
one recording, each chunk backed by its own job. No behaviour lives here.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

CAPABILITIES = (
    "warmup",
    "chunk_sessions",
    "long_poll",
    "flac",
    "priority_queue",
    "final_chunk_finalize",
    "partial_text",
)


def default_settings_path() -> Path:
    return Path.home() / "Library/Application Support/Soma/VoiceServer/settings.json"


def load_settings(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def write_settings(path: Path, settings: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(settings, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(path)


@dataclass
class Job:
    id: str
    client_id: str
    request_id: str
    engine: str
    language: str
    audio_path: str
    idle_seconds: int
    work_class: str = "interactive"
    client_managed_recovery: bool = False
    created_at: float = field(default_factory=time.time)
    started_at: float | None = None
    finished_at: float | None = None
    status: str = "queued"
    text: str = ""
    error: dict[str, Any] | None = None
    infer_seconds: float | None = None
    queued_seconds: float | None = None
    session_id: str | None = None
    chunk_index: int | None = None

    def public(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "job_id": self.id,
            "status": self.status,
            "engine": self.engine,
            "work_class": self.work_class,
            "created_at": self.created_at,
            "queued_seconds": self.queued_seconds,
            "infer_seconds": self.infer_seconds,
        }
        if self.status == "done":
            data["text"] = self.text
        if self.error:
            data["error"] = self.error
        return data


@dataclass
class SessionChunk:
    index: int
    job_id: str
    request_id: str
    reason: str
    overlap_milliseconds: int
    duration_milliseconds: int
    context_chunk_index: int | None = None


class PathologicalRepetitionError(RuntimeError):
    pass


@dataclass
class VoiceSession:
    id: str
    client_id: str
    request_id: str
    engine: str
    language: str
    idle_seconds: int
    created_at: float = field(default_factory=time.time)
    updated_at: float = field(default_factory=time.time)
    next_chunk_index: int = 0
    finalized: bool = False
    canceled: bool = False
    status: str = "recording"
    text: str = ""
    merge_safe: bool = True
    error: dict[str, Any] | None = None
    chunks: dict[int, SessionChunk] = field(default_factory=dict)

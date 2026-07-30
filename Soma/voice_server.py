#!/usr/bin/env python3
"""Soma Voice Server.

Network-facing broker for M1 ASR. It accepts lossless audio chunks, queues requests, and
forwards one job at a time to a warm per-engine backend process.
"""
from __future__ import annotations

import queue
import re
import threading
import time
import uuid
from pathlib import Path
from typing import Any

import voice_jobs
import voice_sessions

# Re-exported so callers and tests keep importing these from voice_server.
from voice_backend_broker import (  # noqa: F401
    BACKEND_HEALTH_IDLE_STOP_SECONDS,
    BACKEND_HEALTH_REFRESH_SECONDS,
    BACKEND_WARMUP_TIMEOUT_SECONDS,
    ENGINES,
    BackendBroker,
)
from voice_cli import install_launch_agent, main, parse_args  # noqa: F401
from voice_http import make_handler  # noqa: F401
from voice_models import (  # noqa: F401
    CAPABILITIES,
    Job,
    PathologicalRepetitionError,
    SessionChunk,
    VoiceSession,
    default_settings_path,
    load_settings,
    write_settings,
)


class VoiceServerState:
    def __init__(
        self,
        token: str,
        broker: BackendBroker,
        default_engine: str = "whisper",
        idle_seconds: int = 3600,
        max_queue: int = 0,
        max_background_queue: int = 0,
        max_audio_bytes: int = 50 * 1024 * 1024,
        upload_timeout_seconds: float = 15.0,
        completed_ttl: int = 7200,
        abandoned_session_ttl: int = 86400,
        allow_unauthenticated_local: bool = False,
        settings_path: Path | None = None,
    ):
        self.token = token.strip()
        self.allow_unauthenticated_local = allow_unauthenticated_local
        self.broker = broker
        self.default_engine = default_engine if default_engine in ENGINES else "whisper"
        self.settings_path = settings_path or default_settings_path()
        saved = load_settings(self.settings_path)
        if "idle_seconds" in saved:
            try:
                idle_seconds = max(0, int(saved["idle_seconds"]))
            except (TypeError, ValueError):
                pass
        self.idle_seconds = idle_seconds
        self.broker.configure(self.idle_seconds)
        self.max_audio_bytes = max_audio_bytes
        self.upload_timeout_seconds = upload_timeout_seconds
        self.completed_ttl = completed_ttl
        self.abandoned_session_ttl = abandoned_session_ttl
        # Zero follows Python's queue convention: unlimited. Imports may build
        # a backlog, while the priority queue still runs live dictation first.
        self.max_queue = max(0, max_queue)
        self.max_background_queue = max(0, max_background_queue)
        self.started_at = time.time()
        self.jobs: dict[str, Job] = {}
        self.idempotency: dict[tuple[str, str], str] = {}
        self.sessions: dict[str, VoiceSession] = {}
        self.session_idempotency: dict[tuple[str, str], str] = {}
        self.pending: queue.PriorityQueue[tuple[int, int, str]] = queue.PriorityQueue(maxsize=self.max_queue)
        self.next_sequence = 0
        self.lock = threading.RLock()
        self.changed = threading.Condition(self.lock)
        self.worker = threading.Thread(target=lambda: voice_jobs.work_loop(self), daemon=True)
        self.worker.start()

    def _request_options(self, headers: dict[str, str]) -> tuple[str, str, str, int] | tuple[None, None, None, None]:
        client_id = headers.get("x-soma-client-id", "unknown").strip() or "unknown"
        request_id = headers.get("x-soma-request-id", "").strip() or str(uuid.uuid4())
        engine = headers.get("x-soma-engine", self.default_engine).strip().lower()
        if engine not in ENGINES:
            return None, None, None, None
        try:
            idle_seconds = max(0, int(headers.get("x-soma-idle-seconds", self.idle_seconds)))
        except ValueError:
            idle_seconds = self.idle_seconds
        return client_id, request_id, engine, idle_seconds

    @staticmethod
    def _work_class(headers: dict[str, str]) -> str | None:
        value = headers.get("x-soma-work-class", "interactive").strip().lower()
        return value if value in {"interactive", "background"} else None

    @staticmethod
    def _language(headers: dict[str, str]) -> str | None:
        # Live recording has always been Russian. Imports opt into `auto` on
        # their session, preserving that behaviour while detecting media files.
        value = headers.get("x-soma-language", "ru").strip().lower()
        return value if value == "auto" or re.fullmatch(r"[a-z]{2,3}", value) else None

    @staticmethod
    def _audio_suffix(headers: dict[str, str]) -> str | None:
        content_type = headers.get("content-type", "audio/wav").split(";", 1)[0].strip().lower()
        # urllib's bare-byte test client labels an otherwise-valid legacy WAV
        # upload as form data. Keep that compatibility while app clients always
        # send an explicit audio MIME type.
        return {
            "": ".wav", "application/x-www-form-urlencoded": ".wav",
            "audio/wav": ".wav", "audio/x-wav": ".wav",
            "audio/flac": ".flac", "audio/x-flac": ".flac",
        }.get(content_type)

    def _queue_error_locked(self, work_class: str) -> tuple[int, dict[str, Any]] | None:
        if self.pending.full():
            return self.error(429, "queue_full", "Soma Voice Server queue is full.", retryable=True)
        if work_class == "background":
            waiting_background = sum(1 for job in self.jobs.values() if job.status == "queued" and job.work_class == "background")
            if self.max_background_queue and waiting_background >= self.max_background_queue:
                return self.error(429, "background_queue_full", "Background media queue is full; live dictation is reserved.", retryable=True)
        return None

    def _enqueue_locked(self, job: Job) -> None:
        priority = 0 if job.work_class == "interactive" else 1
        self.next_sequence += 1
        self.pending.put((priority, self.next_sequence, job.id))

    def submit(self, headers: dict[str, str], body: bytes) -> tuple[int, dict[str, Any]]:
        self._prune()
        if len(body) > self.max_audio_bytes:
            return self.error(413, "audio_too_large", "Audio file is too large.", retryable=False)
        client_id, request_id, engine, idle_seconds = self._request_options(headers)
        if engine is None:
            return self.error(400, "unknown_engine", "Unknown ASR engine.", retryable=False)
        work_class = self._work_class(headers)
        if work_class is None:
            return self.error(400, "bad_work_class", "Work class must be interactive or background.", retryable=False)
        language = self._language(headers)
        if language is None:
            return self.error(400, "bad_language", "ASR language must be auto or an ISO language code.", retryable=False)
        suffix = self._audio_suffix(headers)
        if suffix is None:
            return self.error(415, "unsupported_audio", "Only WAV and FLAC audio are accepted.", retryable=False)
        key = (client_id, request_id)
        with self.changed:
            existing = self.idempotency.get(key)
            if existing and existing in self.jobs:
                return 202, self.jobs[existing].public()
            if error := self._queue_error_locked(work_class):
                return error
            job = self._new_job(client_id, request_id, engine, language, idle_seconds, body, work_class, suffix)
            self.jobs[job.id] = job
            self.idempotency[key] = job.id
            self._enqueue_locked(job)
            self.changed.notify_all()
            return 202, job.public()

    def warm(self, headers: dict[str, str]) -> tuple[int, dict[str, Any]]:
        _client_id, _request_id, engine, idle_seconds = self._request_options(headers)
        if engine is None:
            return self.error(400, "unknown_engine", "Unknown ASR engine.", retryable=False)
        try:
            result = self.broker.warm(engine, idle_seconds)
            return 200, result
        except Exception as exc:
            return self.error(503, "warmup_failed", str(exc), retryable=True)

    # Chunk-session endpoints live in voice_sessions; these keep the public API.

    def create_session(self, headers: dict[str, str]) -> tuple[int, dict[str, Any]]:
        return voice_sessions.create(self, headers)

    def submit_session_chunk(self, session_id: str, index: int, headers: dict[str, str], body: bytes) -> tuple[int, dict[str, Any]]:
        return voice_sessions.submit_chunk(self, session_id, index, headers, body)

    def finalize_session(self, session_id: str, headers: dict[str, str]) -> tuple[int, dict[str, Any]]:
        return voice_sessions.finalize(self, session_id, headers)

    def cancel_session(self, session_id: str, headers: dict[str, str]) -> tuple[int, dict[str, Any]]:
        return voice_sessions.cancel(self, session_id, headers)

    def get(self, job_id: str, wait_seconds: float = 0) -> tuple[int, dict[str, Any]]:
        self._prune()
        with self.changed:
            job = self.jobs.get(job_id)
            if not job:
                return self.error(404, "job_not_found", "Transcription job was not found or expired.", retryable=False)
            deadline = time.monotonic() + wait_seconds
            while wait_seconds > 0 and job.status in {"queued", "running"}:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self.changed.wait(remaining)
            return 200, job.public()

    def get_session(self, session_id: str, headers: dict[str, str], wait_seconds: float = 0) -> tuple[int, dict[str, Any]]:
        self._prune()
        client_id = headers.get("x-soma-client-id", "unknown").strip() or "unknown"
        with self.changed:
            session = self.sessions.get(session_id)
            if not session:
                return self.error(404, "session_not_found", "Voice session was not found or expired.", retryable=False)
            if session.client_id != client_id:
                return self.error(403, "session_client_mismatch", "Voice session belongs to another client.", retryable=False)
            deadline = time.monotonic() + wait_seconds
            while wait_seconds > 0 and session.status in {"recording", "finalizing"}:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self.changed.wait(remaining)
            return 200, voice_sessions.public_locked(self, session)

    def health(self) -> dict[str, Any]:
        with self.lock:
            jobs = list(self.jobs.values())
        queued = sum(1 for job in jobs if job.status == "queued")
        running = sum(1 for job in jobs if job.status == "running")
        return {
            "ok": True,
            "version": 2,
            "capabilities": list(CAPABILITIES),
            "uptime_seconds": round(time.time() - self.started_at, 1),
            "queue_depth": queued,
            "running": running,
            "default_engine": self.default_engine,
            "idle_seconds": self.idle_seconds,
            **self.broker.health(),
        }

    def status(self) -> dict[str, Any]:
        with self.lock:
            jobs = list(self.jobs.values())
        queued_jobs = [job.public() for job in jobs if job.status == "queued"]
        running_jobs = [job.public() for job in jobs if job.status == "running"]
        failed_count = sum(1 for job in jobs if job.status == "failed")
        done_count = sum(1 for job in jobs if job.status == "done")
        return {
            "ok": True,
            "version": 2,
            "capabilities": list(CAPABILITIES),
            "server": {
                "uptime_seconds": round(time.time() - self.started_at, 1),
                "default_engine": self.default_engine,
                "engines": ENGINES,
            },
            "settings": {"idle_seconds": self.idle_seconds, "settings_path": str(self.settings_path)},
            "queue": {
                "queued": len(queued_jobs),
                "running": len(running_jobs),
                "max": self.pending.maxsize or None,
                "max_background": self.max_background_queue or None,
                "active_job": running_jobs[0] if running_jobs else None,
                "queued_jobs": queued_jobs[:20],
                "done": done_count,
                "failed": failed_count,
            },
            "backend": self.broker.health(),
        }

    def update_settings(self, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        if "idle_seconds" not in payload:
            return self.error(400, "missing_idle_seconds", "idle_seconds is required.", retryable=False)
        try:
            idle_seconds = max(0, int(payload["idle_seconds"]))
        except (TypeError, ValueError):
            return self.error(400, "bad_idle_seconds", "idle_seconds must be a number.", retryable=False)
        self.idle_seconds = idle_seconds
        try:
            self.broker.configure(idle_seconds)
            write_settings(self.settings_path, {"idle_seconds": idle_seconds})
        except Exception as exc:
            return self.error(503, "settings_update_failed", str(exc), retryable=True)
        return 200, self.status()

    def _prune(self) -> None:
        voice_jobs.prune(self)

    def _new_job(self, client_id: str, request_id: str, engine: str, language: str, idle_seconds: int, body: bytes, work_class: str, suffix: str, client_managed_recovery: bool = False) -> Job:
        return voice_jobs.new_job(self, client_id, request_id, engine, language, idle_seconds, body, work_class, suffix, client_managed_recovery)

    @staticmethod
    def error(code: int, error_code: str, message: str, retryable: bool) -> tuple[int, dict[str, Any]]:
        return code, {"error": {"code": error_code, "message": message, "retryable": retryable}}

if __name__ == "__main__":
    main()

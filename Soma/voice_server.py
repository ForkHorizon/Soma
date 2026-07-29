#!/usr/bin/env python3
"""Soma Voice Server.

Network-facing broker for M1 ASR. It accepts lossless audio chunks, queues requests, and
forwards one job at a time to a warm per-engine backend process.
"""
from __future__ import annotations

import argparse
import hmac
import json
import os
import plistlib
import queue
import re
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit

ENGINES = {
    "whisper": "Whisper large-v3",
    "gigaam": "GigaAM v2 (Russian)",
}

CAPABILITIES = ("warmup", "chunk_sessions", "long_poll", "flac", "priority_queue", "final_chunk_finalize")


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


class BackendBroker:
    def __init__(self, asr_root: Path, runtime_dir: Path, idle_seconds: int, models_root: Path | None = None):
        self.asr_root = asr_root.expanduser()
        self.runtime_dir = runtime_dir.expanduser()
        self.idle_seconds = idle_seconds
        self.models_root = models_root.expanduser() if models_root else self.asr_root / "asr-models"
        self.script = Path(__file__).with_name("voice_asr_backend.py")
        self.process: subprocess.Popen[str] | None = None
        self.engine: str | None = None
        self.port: int | None = None
        self.lock = threading.Lock()

    def health(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "active_engine": self.engine,
            "active_port": self.port,
            "backend_running": bool(self.process and self.process.poll() is None),
            "backend_loaded": False,
            "backend_idle_seconds": None,
            "backend_last_used_seconds_ago": None,
        }
        if data["backend_running"] and self.port:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/health", timeout=2) as response:
                    health = json.loads(response.read().decode())
                data["backend_loaded"] = bool(health.get("loaded"))
                data["backend_idle_seconds"] = health.get("idle_seconds")
                data["backend_last_used_seconds_ago"] = health.get("last_used_seconds_ago")
            except Exception as exc:
                data["backend_error"] = str(exc)
        return data

    def configure(self, idle_seconds: int) -> None:
        self.idle_seconds = max(0, int(idle_seconds))
        if not (self.process and self.process.poll() is None and self.port):
            return
        payload = json.dumps({"idle_seconds": self.idle_seconds}).encode()
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/configure",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as response:
            response.read()

    def warm(self, engine: str, idle_seconds: int | None = None) -> dict[str, Any]:
        if engine not in ENGINES:
            raise RuntimeError(f"unknown_engine:{engine}")
        with self.lock:
            effective_idle = self.idle_seconds if idle_seconds is None else idle_seconds
            port = self._ensure_backend(engine, effective_idle)
            return self._post_backend(port, "/warmup", {"idle_seconds": effective_idle})

    def transcribe(
        self,
        engine: str,
        audio_path: str,
        idle_seconds: int | None = None,
        initial_prompt: str | None = None,
        language: str = "ru",
    ) -> dict[str, Any]:
        if engine not in ENGINES:
            raise RuntimeError(f"unknown_engine:{engine}")
        with self.lock:
            effective_idle = self.idle_seconds if idle_seconds is None else idle_seconds
            port = self._ensure_backend(engine, effective_idle)
            payload: dict[str, Any] = {"audio": audio_path, "idle_seconds": effective_idle, "language": language}
            if initial_prompt:
                payload["initial_prompt"] = initial_prompt
            return self._post_backend(port, "/transcribe", payload, timeout=900)

    @staticmethod
    def _post_backend(port: int, path: str, payload: dict[str, Any], timeout: int = 30) -> dict[str, Any]:
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}{path}",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                body = response.read()
        except urllib.error.HTTPError as exc:
            body = exc.read()
            try:
                obj = json.loads(body.decode())
            except Exception:
                obj = {"error": str(exc)}
            raise RuntimeError(obj.get("error") or str(exc)) from exc
        return json.loads(body.decode())

    def _ensure_backend(self, engine: str, idle_seconds: int) -> int:
        if self.engine == engine and self.process and self.process.poll() is None and self.port:
            return self.port
        self.stop()
        self.runtime_dir.mkdir(parents=True, exist_ok=True)
        port_file = self.runtime_dir / f"{engine}.port"
        log_file = self.runtime_dir / f"{engine}.log"
        try:
            port_file.unlink()
        except FileNotFoundError:
            pass
        python = self.asr_root / f"venv-{engine}" / "bin" / "python"
        if not python.exists():
            raise RuntimeError(f"ASR venv not found: {python}")
        if not self.script.exists():
            raise RuntimeError(f"ASR backend script not found: {self.script}")

        env = os.environ.copy()
        env.update(
            {
                "ASR_ENGINE": engine,
                "ASR_PORT": "0",
                "ASR_PORT_FILE": str(port_file),
                "ASR_IDLE_SECONDS": str(idle_seconds),
                "HF_HOME": str(self.models_root / "hf"),
                "ASR_GIGAAM_ROOT": str(self.models_root / "gigaam"),
                "PYTORCH_ENABLE_MPS_FALLBACK": "1",
                "PYTHONUNBUFFERED": "1",
                "PATH": f"/opt/homebrew/bin:/usr/local/bin:{env.get('PATH', '')}",
            }
        )
        with log_file.open("a", encoding="utf-8") as log_handle:
            self.process = subprocess.Popen(
                [str(python), str(self.script)],
                cwd=str(self.asr_root),
                env=env,
                stdout=log_handle,
                stderr=log_handle,
                text=True,
            )
        self.engine = engine
        self.port = None
        deadline = time.time() + 90
        while time.time() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError(f"ASR backend exited for {engine}; see {log_file}")
            if port_file.exists():
                value = port_file.read_text(encoding="utf-8").strip()
                if value.isdigit():
                    self.port = int(value)
                    return self.port
            time.sleep(0.25)
        raise RuntimeError(f"ASR backend did not start for {engine}; see {log_file}")

    def stop(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.process = None
        self.engine = None
        self.port = None


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
        self.worker = threading.Thread(target=self._work, daemon=True)
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

    def create_session(self, headers: dict[str, str]) -> tuple[int, dict[str, Any]]:
        self._prune()
        client_id, request_id, engine, idle_seconds = self._request_options(headers)
        if engine is None:
            return self.error(400, "unknown_engine", "Unknown ASR engine.", retryable=False)
        language = self._language(headers)
        if language is None:
            return self.error(400, "bad_language", "ASR language must be auto or an ISO language code.", retryable=False)
        key = (client_id, request_id)
        with self.changed:
            existing = self.session_idempotency.get(key)
            if existing and existing in self.sessions:
                return 200, self._session_public_locked(self.sessions[existing])
            session = VoiceSession(
                id=str(uuid.uuid4()),
                client_id=client_id,
                request_id=request_id,
                engine=engine,
                language=language,
                idle_seconds=idle_seconds,
            )
            self.sessions[session.id] = session
            self.session_idempotency[key] = session.id
            self.changed.notify_all()
            return 201, self._session_public_locked(session)

    def submit_session_chunk(
        self,
        session_id: str,
        index: int,
        headers: dict[str, str],
        body: bytes,
    ) -> tuple[int, dict[str, Any]]:
        self._prune()
        if len(body) > self.max_audio_bytes:
            return self.error(413, "audio_too_large", "Audio file is too large.", retryable=False)
        if index < 0:
            return self.error(400, "bad_chunk_index", "Chunk index must be non-negative.", retryable=False)
        client_id = headers.get("x-soma-client-id", "unknown").strip() or "unknown"
        request_id = headers.get("x-soma-request-id", "").strip()
        if not request_id:
            return self.error(400, "missing_request_id", "Chunk uploads require X-Soma-Request-ID.", retryable=False)
        work_class = self._work_class(headers)
        if work_class is None:
            return self.error(400, "bad_work_class", "Work class must be interactive or background.", retryable=False)
        suffix = self._audio_suffix(headers)
        if suffix is None:
            return self.error(415, "unsupported_audio", "Only WAV and FLAC audio are accepted.", retryable=False)
        reason = headers.get("x-soma-chunk-reason", "pause").strip().lower()
        if reason not in {"pause", "forced", "final"}:
            return self.error(400, "bad_chunk_reason", "Chunk reason must be pause, forced, or final.", retryable=False)
        finalize_with_chunk = headers.get("x-soma-finalize-session", "").strip() == "1"
        retry_failed_chunk = headers.get("x-soma-retry-failed-chunk", "").strip() == "1"
        client_managed_recovery = headers.get("x-soma-chunk-recovery", "").strip() == "client-v1"
        context_chunk_index: int | None = None
        context_value = headers.get("x-soma-context-chunk-index", "").strip()
        if context_value:
            try:
                context_chunk_index = int(context_value)
            except ValueError:
                return self.error(400, "bad_context_chunk", "Context chunk index must be an integer.", retryable=False)
            if context_chunk_index != index - 1:
                return self.error(400, "bad_context_chunk", "Context must be the immediately preceding chunk.", retryable=False)
        if finalize_with_chunk and reason != "final":
            return self.error(400, "bad_finalization", "Only a final chunk can finalize a session.", retryable=False)
        try:
            overlap = max(0, int(headers.get("x-soma-overlap-milliseconds", "0")))
            duration = max(0, int(headers.get("x-soma-chunk-duration-milliseconds", "0")))
        except ValueError:
            return self.error(400, "bad_chunk_metadata", "Chunk overlap and duration must be integers.", retryable=False)

        with self.changed:
            session = self.sessions.get(session_id)
            if not session:
                return self.error(404, "session_not_found", "Voice session was not found or expired.", retryable=False)
            if session.client_id != client_id:
                return self.error(403, "session_client_mismatch", "Voice session belongs to another client.", retryable=False)
            if session.canceled:
                return self.error(409, "session_canceled", "Voice session was canceled.", retryable=False)
            existing = session.chunks.get(index)
            if session.finalized and not existing:
                return self.error(409, "session_finalized", "Voice session has already been finalized.", retryable=False)
            if existing:
                existing_job = self.jobs.get(existing.job_id)
                if not existing_job:
                    return self.error(409, "chunk_job_missing", "Chunk job is no longer available.", retryable=True)
                if existing.request_id == request_id or existing_job.status != "failed":
                    return 202, self.jobs[existing.job_id].public()
                if not retry_failed_chunk:
                    return 202, existing_job.public()
            if not existing and index != session.next_chunk_index:
                return 409, {
                    "error": {
                        "code": "chunk_out_of_order",
                        "message": "Chunk index must be the next expected index.",
                        "retryable": True,
                    },
                    "expected_chunk_index": session.next_chunk_index,
                }
            if error := self._queue_error_locked(work_class):
                return error
            job = self._new_job(
                session.client_id,
                request_id,
                session.engine,
                session.language,
                session.idle_seconds,
                body,
                work_class,
                suffix,
                client_managed_recovery,
            )
            job.session_id = session.id
            job.chunk_index = index
            self.jobs[job.id] = job
            self.idempotency[(session.client_id, request_id)] = job.id
            session.chunks[index] = SessionChunk(index, job.id, request_id, reason, overlap, duration, context_chunk_index)
            if not existing:
                session.next_chunk_index += 1
            if finalize_with_chunk:
                session.finalized = True
                self._refresh_session_locked(session)
            session.updated_at = time.time()
            self._enqueue_locked(job)
            self.changed.notify_all()
            return 202, job.public()

    def finalize_session(self, session_id: str, headers: dict[str, str]) -> tuple[int, dict[str, Any]]:
        client_id = headers.get("x-soma-client-id", "unknown").strip() or "unknown"
        with self.changed:
            session = self.sessions.get(session_id)
            if not session:
                return self.error(404, "session_not_found", "Voice session was not found or expired.", retryable=False)
            if session.client_id != client_id:
                return self.error(403, "session_client_mismatch", "Voice session belongs to another client.", retryable=False)
            if session.canceled:
                return self.error(409, "session_canceled", "Voice session was canceled.", retryable=False)
            session.finalized = True
            session.updated_at = time.time()
            self._refresh_session_locked(session)
            self.changed.notify_all()
            return 200, self._session_public_locked(session)

    def cancel_session(self, session_id: str, headers: dict[str, str]) -> tuple[int, dict[str, Any]]:
        client_id = headers.get("x-soma-client-id", "unknown").strip() or "unknown"
        with self.changed:
            session = self.sessions.get(session_id)
            if not session:
                return self.error(404, "session_not_found", "Voice session was not found or expired.", retryable=False)
            if session.client_id != client_id:
                return self.error(403, "session_client_mismatch", "Voice session belongs to another client.", retryable=False)
            session.canceled = True
            session.status = "canceled"
            session.updated_at = time.time()
            for chunk in session.chunks.values():
                job = self.jobs.get(chunk.job_id)
                if job and job.status in {"queued", "running"}:
                    job.status = "canceled"
                    job.error = {"code": "session_canceled", "message": "Voice session was canceled.", "retryable": False}
            self.changed.notify_all()
            return 200, self._session_public_locked(session)

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
            return 200, self._session_public_locked(session)

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

    @staticmethod
    def error(code: int, error_code: str, message: str, retryable: bool) -> tuple[int, dict[str, Any]]:
        return code, {"error": {"code": error_code, "message": message, "retryable": retryable}}

    def _new_job(self, client_id: str, request_id: str, engine: str, language: str, idle_seconds: int, body: bytes, work_class: str, suffix: str, client_managed_recovery: bool = False) -> Job:
        fd, path = tempfile.mkstemp(prefix="soma-voice-", suffix=suffix)
        with os.fdopen(fd, "wb") as handle:
            handle.write(body)
        return Job(
            id=str(uuid.uuid4()),
            client_id=client_id,
            request_id=request_id,
            engine=engine,
            language=language,
            audio_path=path,
            idle_seconds=max(0, idle_seconds),
            work_class=work_class,
            client_managed_recovery=client_managed_recovery,
        )

    def _work(self) -> None:
        while True:
            _priority, _sequence, job_id = self.pending.get()
            job: Job | None = None
            initial_prompt: str | None = None
            try:
                with self.changed:
                    job = self.jobs.get(job_id)
                    if not job or job.status == "canceled":
                        continue
                    job.status = "running"
                    job.started_at = time.time()
                    job.queued_seconds = round(job.started_at - job.created_at, 2)
                    initial_prompt = self._session_prompt_locked(job)
                    self.changed.notify_all()
                result = self.broker.transcribe(job.engine, job.audio_path, job.idle_seconds, initial_prompt, job.language)
                text = str(result.get("text") or "").strip()
                if job.work_class == "background" and self._has_pathological_repetition(text):
                    if not job.client_managed_recovery:
                        result = self.broker.transcribe(job.engine, job.audio_path, job.idle_seconds, None, job.language)
                        text = str(result.get("text") or "").strip()
                        if self._has_pathological_repetition(text):
                            raise PathologicalRepetitionError("pathological_repetition")
                    else:
                        raise PathologicalRepetitionError("pathological_repetition")
                with self.changed:
                    session = self.sessions.get(job.session_id) if job.session_id else None
                    if job.status == "canceled" or (session and session.canceled):
                        job.status = "canceled"
                    else:
                        job.text = text
                        job.infer_seconds = result.get("infer_seconds")
                        job.status = "done"
                    job.finished_at = time.time()
                    if session:
                        self._refresh_session_locked(session)
                    self.changed.notify_all()
            except Exception as exc:
                with self.changed:
                    if job:
                        session = self.sessions.get(job.session_id) if job.session_id else None
                        if job.status != "canceled" and not (session and session.canceled):
                            job.status = "failed"
                            error_code = "pathological_repetition" if isinstance(exc, PathologicalRepetitionError) else "transcription_failed"
                            job.error = {"code": error_code, "message": str(exc), "retryable": True}
                        job.finished_at = time.time()
                        if session:
                            self._refresh_session_locked(session)
                    self.changed.notify_all()
            finally:
                if job:
                    try:
                        os.remove(job.audio_path)
                    except FileNotFoundError:
                        pass
                self.pending.task_done()

    def _session_prompt_locked(self, job: Job) -> str | None:
        if not job.session_id or job.chunk_index is None or job.engine != "whisper":
            return None
        session = self.sessions.get(job.session_id)
        if not session:
            return None
        chunk = session.chunks.get(job.chunk_index)
        # Pause-separated chunks are independent phrases. Giving Whisper the
        # prior transcript there can make it echo that text, which the normal
        # append path correctly cannot treat as an audio overlap. Only forced
        # chunks intentionally replay audio and therefore need text context.
        if not chunk or chunk.reason != "forced":
            return None
        text, _safe = self._merge_session_locked(session, stop_before=job.chunk_index)
        words = text.split()
        return " ".join(words[-50:]) if words else None

    def _refresh_session_locked(self, session: VoiceSession) -> None:
        session.updated_at = time.time()
        if session.canceled:
            session.status = "canceled"
            return
        jobs = [self.jobs[chunk.job_id] for chunk in session.chunks.values() if chunk.job_id in self.jobs]
        failed = next((job for job in jobs if job.status == "failed"), None)
        if failed:
            session.status = "failed"
            session.error = failed.error or {"code": "transcription_failed", "message": "A chunk failed.", "retryable": True}
            return
        if session.finalized:
            if all(job.status == "done" for job in jobs):
                session.text, session.merge_safe = self._merge_session_locked(session)
                session.status = "done"
            else:
                session.status = "finalizing"
        else:
            session.status = "recording"

    def _session_public_locked(self, session: VoiceSession) -> dict[str, Any]:
        chunks = [session.chunks[index] for index in sorted(session.chunks)]
        jobs = [self.jobs.get(chunk.job_id) for chunk in chunks]
        completed = sum(1 for job in jobs if job and job.status == "done")
        queued_seconds = round(sum((job.queued_seconds or 0) for job in jobs if job), 2)
        infer_seconds = round(sum((job.infer_seconds or 0) for job in jobs if job), 2)
        data: dict[str, Any] = {
            "session_id": session.id,
            "status": session.status,
            "engine": session.engine,
            "next_chunk_index": session.next_chunk_index,
            "accepted_chunks": len(chunks),
            "completed_chunks": completed,
            "finalized": session.finalized,
            "merge_safe": session.merge_safe,
            "metrics": {
                "queued_seconds": queued_seconds,
                "infer_seconds": infer_seconds,
                "duration_milliseconds": sum(chunk.duration_milliseconds for chunk in chunks),
            },
        }
        if session.status == "done":
            data["text"] = session.text
        if session.error:
            data["error"] = session.error
        return data

    def _merge_session_locked(self, session: VoiceSession, stop_before: int | None = None) -> tuple[str, bool]:
        text = ""
        safe = True
        for index in sorted(session.chunks):
            if stop_before is not None and index >= stop_before:
                break
            chunk = session.chunks[index]
            job = self.jobs.get(chunk.job_id)
            if not job or job.status != "done":
                continue
            incoming = " ".join(job.text.split())
            if not incoming:
                continue
            if chunk.context_chunk_index is not None:
                context = session.chunks.get(chunk.context_chunk_index)
                context_job = self.jobs.get(context.job_id) if context else None
                if not context_job or context_job.status != "done":
                    safe = False
                else:
                    incoming, stripped = self._strip_context_prefix(context_job.text, incoming)
                    safe = safe and stripped
            if not text:
                text = incoming
                continue
            if chunk.overlap_milliseconds > 0:
                text, matched = self._join_overlap(text, incoming)
                safe = safe and matched
            else:
                text = f"{text} {incoming}".strip()
        return text, safe

    @staticmethod
    def _strip_context_prefix(context: str, incoming: str) -> tuple[str, bool]:
        context_words = context.split()
        incoming_words = incoming.split()
        if not context_words:
            return incoming, True
        count = len(context_words)
        if len(incoming_words) <= count:
            return incoming, False
        if [VoiceServerState._normalized_word(word) for word in incoming_words[:count]] != [VoiceServerState._normalized_word(word) for word in context_words]:
            return incoming, False
        return " ".join(incoming_words[count:]).strip(), True

    @staticmethod
    def _has_pathological_repetition(text: str) -> bool:
        punctuation_run = 0
        previous_punctuation = ""
        for raw_word in text.split():
            word = VoiceServerState._normalized_word(raw_word)
            punctuation = "".join(character for character in raw_word if not character.isalnum())
            if not word and punctuation:
                punctuation_run = punctuation_run + 1 if punctuation == previous_punctuation else 1
                if punctuation_run >= 8:
                    return True
            else:
                punctuation_run = 0
            previous_punctuation = punctuation
        words = [VoiceServerState._normalized_word(word) for word in text.split()]
        words = [word for word in words if word]
        # Decoder loops can alternate between words or repeat a short phrase.
        # Detect a unit of up to eight words repeated at least three times.
        for unit_length in range(1, min(8, len(words) // 3) + 1):
            minimum_length = max(12, unit_length * 3)
            for start in range(0, len(words) - minimum_length + 1):
                if all(words[start + offset] == words[start + offset % unit_length] for offset in range(unit_length, minimum_length)):
                    return True
        return False

    @staticmethod
    def _join_overlap(existing: str, incoming: str) -> tuple[str, bool]:
        left = existing.split()
        right = incoming.split()
        max_overlap = min(len(left), len(right), 16)
        for count in range(max_overlap, 0, -1):
            if [VoiceServerState._normalized_word(word) for word in left[-count:]] == [VoiceServerState._normalized_word(word) for word in right[:count]]:
                return " ".join(left + right[count:]).strip(), True
        return f"{existing} {incoming}".strip(), False

    @staticmethod
    def _normalized_word(word: str) -> str:
        return re.sub(r"[^\w]+", "", word, flags=re.UNICODE).casefold()

    def _prune(self) -> None:
        cutoff = time.time() - self.completed_ttl
        abandoned_cutoff = time.time() - self.abandoned_session_ttl
        with self.changed:
            expired_jobs = [job_id for job_id, job in self.jobs.items() if job.finished_at is not None and job.finished_at < cutoff]
            for job_id in expired_jobs:
                job = self.jobs.pop(job_id, None)
                if job:
                    self.idempotency.pop((job.client_id, job.request_id), None)
            expired_sessions = [
                session_id
                for session_id, session in self.sessions.items()
                if session.status in {"done", "failed", "canceled"} and session.updated_at < cutoff
            ]
            for session_id in expired_sessions:
                session = self.sessions.pop(session_id, None)
                if session:
                    self.session_idempotency.pop((session.client_id, session.request_id), None)
            abandoned_sessions = [
                session_id
                for session_id, session in self.sessions.items()
                if session.status in {"recording", "finalizing"} and session.updated_at < abandoned_cutoff
            ]
            for session_id in abandoned_sessions:
                session = self.sessions.get(session_id)
                if not session:
                    continue
                session.canceled = True
                session.status = "canceled"
                for chunk in session.chunks.values():
                    job = self.jobs.get(chunk.job_id)
                    if job and job.status in {"queued", "running"}:
                        job.status = "canceled"
                        job.error = {"code": "session_expired", "message": "Voice session expired.", "retryable": True}
                self.sessions.pop(session_id, None)
                self.session_idempotency.pop((session.client_id, session.request_id), None)


def make_handler(state: VoiceServerState) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _auth_ok(self) -> bool:
            if state.token:
                return hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {state.token}")
            return state.allow_unauthenticated_local and self.client_address[0] in {"127.0.0.1", "::1"}

        def _content_length(self) -> int | None:
            try:
                length = int(self.headers.get("Content-Length", 0))
                if length < 0:
                    raise ValueError
                return length
            except ValueError:
                self._reply(*state.error(400, "bad_content_length", "Invalid Content-Length.", retryable=False))
                return None

        def _reply(self, code: int, obj: dict[str, Any]) -> None:
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _read_body(self, content_length: int) -> bytes | None:
            previous_timeout = self.connection.gettimeout()
            self.connection.settimeout(state.upload_timeout_seconds)
            try:
                body = self.rfile.read(content_length)
            except (TimeoutError, socket.timeout, OSError):
                self.close_connection = True
                self._reply(*state.error(408, "upload_timeout", "Timed out while receiving audio bytes.", retryable=True))
                return None
            finally:
                try:
                    self.connection.settimeout(previous_timeout)
                except OSError:
                    pass
            if len(body) != content_length:
                self.close_connection = True
                self._reply(*state.error(
                    400,
                    "incomplete_upload",
                    "Upload ended before all audio bytes were received.",
                    retryable=True,
                ))
                return None
            return body

        def _guard_auth(self) -> bool:
            if self._auth_ok():
                return True
            self._reply(*state.error(401, "unauthorized", "Missing or invalid Soma Voice token.", retryable=False))
            return False

        @staticmethod
        def _wait_seconds(query: dict[str, list[str]]) -> float:
            try:
                return max(0.0, min(25.0, float(query.get("wait", ["0"])[0])))
            except (TypeError, ValueError):
                return 0.0

        def _headers(self) -> dict[str, str]:
            return {key.lower(): value for key, value in self.headers.items()}

        def do_GET(self) -> None:
            if not self._guard_auth():
                return
            parsed = urlsplit(self.path)
            if parsed.path == "/v1/health":
                self._reply(200, state.health())
                return
            if parsed.path == "/v1/status":
                self._reply(200, state.status())
                return
            prefix = "/v1/transcriptions/"
            if parsed.path.startswith(prefix):
                self._reply(*state.get(parsed.path.removeprefix(prefix), self._wait_seconds(parse_qs(parsed.query))))
                return
            session_prefix = "/v1/sessions/"
            if parsed.path.startswith(session_prefix):
                self._reply(*state.get_session(
                    parsed.path.removeprefix(session_prefix),
                    self._headers(),
                    self._wait_seconds(parse_qs(parsed.query)),
                ))
                return
            self._reply(*state.error(404, "not_found", "Endpoint not found.", retryable=False))

        def do_PATCH(self) -> None:
            if not self._guard_auth():
                return
            if self.path != "/v1/settings":
                self._reply(*state.error(404, "not_found", "Endpoint not found.", retryable=False))
                return
            content_length = self._content_length()
            if content_length is None:
                return
            body = self._read_body(content_length)
            if body is None:
                return
            try:
                payload = json.loads(body.decode() or "{}")
            except json.JSONDecodeError:
                self._reply(*state.error(400, "bad_json", "Request body must be JSON.", retryable=False))
                return
            if not isinstance(payload, dict):
                self._reply(*state.error(400, "bad_json", "Request body must be a JSON object.", retryable=False))
                return
            self._reply(*state.update_settings(payload))

        def do_POST(self) -> None:
            if not self._guard_auth():
                return
            parsed = urlsplit(self.path)
            if parsed.path == "/v1/warmup":
                self._reply(*state.warm(self._headers()))
                return
            if parsed.path == "/v1/sessions":
                self._reply(*state.create_session(self._headers()))
                return
            session_prefix = "/v1/sessions/"
            if parsed.path.startswith(session_prefix) and parsed.path.endswith("/finalize"):
                session_id = parsed.path.removeprefix(session_prefix).removesuffix("/finalize")
                self._reply(*state.finalize_session(session_id, self._headers()))
                return
            if parsed.path != "/v1/transcriptions":
                self._reply(*state.error(404, "not_found", "Endpoint not found.", retryable=False))
                return
            content_length = self._content_length()
            if content_length is None:
                return
            if content_length > state.max_audio_bytes:
                self.close_connection = True
                self._reply(*state.error(413, "audio_too_large", "Audio file is too large.", retryable=False))
                return
            body = self._read_body(content_length)
            if body is None:
                return
            self._reply(*state.submit(self._headers(), body))

        def do_PUT(self) -> None:
            if not self._guard_auth():
                return
            parsed = urlsplit(self.path)
            prefix = "/v1/sessions/"
            if not parsed.path.startswith(prefix):
                self._reply(*state.error(404, "not_found", "Endpoint not found.", retryable=False))
                return
            parts = parsed.path.removeprefix(prefix).split("/")
            if len(parts) != 3 or parts[1] != "chunks" or not parts[0]:
                self._reply(*state.error(404, "not_found", "Endpoint not found.", retryable=False))
                return
            try:
                index = int(parts[2])
            except ValueError:
                self._reply(*state.error(400, "bad_chunk_index", "Chunk index must be an integer.", retryable=False))
                return
            content_length = self._content_length()
            if content_length is None:
                return
            if content_length > state.max_audio_bytes:
                self.close_connection = True
                self._reply(*state.error(413, "audio_too_large", "Audio file is too large.", retryable=False))
                return
            body = self._read_body(content_length)
            if body is None:
                return
            self._reply(*state.submit_session_chunk(parts[0], index, self._headers(), body))

        def do_DELETE(self) -> None:
            if not self._guard_auth():
                return
            parsed = urlsplit(self.path)
            prefix = "/v1/sessions/"
            session_id = parsed.path.removeprefix(prefix) if parsed.path.startswith(prefix) else ""
            if not session_id or "/" in session_id:
                self._reply(*state.error(404, "not_found", "Endpoint not found.", retryable=False))
                return
            self._reply(*state.cancel_session(session_id, self._headers()))

        def log_message(self, *_args) -> None:
            pass

    return Handler


def install_launch_agent(args: argparse.Namespace) -> Path:
    plist = Path.home() / "Library/LaunchAgents/com.daliys.soma.voice-server.plist"
    plist.parent.mkdir(parents=True, exist_ok=True)
    env = {}
    token = args.token or os.environ.get("SOMA_VOICE_TOKEN")
    if token:
        env["SOMA_VOICE_TOKEN"] = token
    program_args = [
        sys.executable,
        str(Path(__file__).resolve()),
        "--host",
        args.host,
        "--port",
        str(args.port),
        "--asr-root",
        str(args.asr_root),
        "--idle-seconds",
        str(args.idle_seconds),
        "--max-queue",
        str(args.max_queue),
        "--max-background-queue",
        str(args.max_background_queue),
        "--abandoned-session-ttl",
        str(args.abandoned_session_ttl),
    ]
    if args.models_root:
        program_args += ["--models-root", str(args.models_root)]
    if args.allow_unauthenticated_local:
        program_args.append("--allow-unauthenticated-local")
    data = {
        "Label": "com.daliys.soma.voice-server",
        "ProgramArguments": program_args,
        "EnvironmentVariables": env,
        "RunAtLoad": True,
        "KeepAlive": True,
        "StandardOutPath": str(Path.home() / "Library/Logs/soma-voice-server.out.log"),
        "StandardErrorPath": str(Path.home() / "Library/Logs/soma-voice-server.err.log"),
    }
    plist.write_bytes(plistlib.dumps(data))
    return plist


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run Soma Voice Server")
    parser.add_argument("--host", default=os.environ.get("SOMA_VOICE_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("SOMA_VOICE_PORT", "8765")))
    parser.add_argument("--token", default=os.environ.get("SOMA_VOICE_TOKEN", ""))
    parser.add_argument("--asr-root", type=Path, default=Path(os.environ.get("SOMA_VOICE_ASR_ROOT", "~/soma-asr-bench")).expanduser())
    parser.add_argument("--models-root", type=Path, default=None)
    parser.add_argument("--idle-seconds", type=int, default=int(os.environ.get("SOMA_VOICE_IDLE_SECONDS", "3600")))
    parser.add_argument("--max-queue", type=int, default=int(os.environ.get("SOMA_VOICE_MAX_QUEUE", "0")))
    parser.add_argument("--max-background-queue", type=int, default=int(os.environ.get("SOMA_VOICE_MAX_BACKGROUND_QUEUE", "0")))
    parser.add_argument("--abandoned-session-ttl", type=int, default=int(os.environ.get("SOMA_VOICE_ABANDONED_SESSION_TTL", "86400")))
    parser.add_argument("--install-launch-agent", action="store_true")
    parser.add_argument("--allow-unauthenticated-local", action="store_true", help="Allow local-only requests without a bearer token")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    args.token = args.token.strip()
    if not args.token and not args.allow_unauthenticated_local:
        print("SOMA_VOICE_TOKEN is required unless --allow-unauthenticated-local is set.", file=sys.stderr)
        raise SystemExit(2)
    if args.install_launch_agent:
        plist = install_launch_agent(args)
        print(f"installed {plist}")
        return

    runtime_dir = Path.home() / "Library/Application Support/Soma/VoiceServer"
    broker = BackendBroker(args.asr_root, runtime_dir, args.idle_seconds, args.models_root)
    state = VoiceServerState(
        args.token,
        broker,
        idle_seconds=args.idle_seconds,
        max_queue=args.max_queue,
        max_background_queue=args.max_background_queue,
        abandoned_session_ttl=args.abandoned_session_ttl,
        allow_unauthenticated_local=args.allow_unauthenticated_local,
    )
    server = ThreadingHTTPServer((args.host, args.port), make_handler(state))

    def stop(_signum: int, _frame: Any) -> None:
        broker.stop()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(f"[soma-voice-server] listening on {args.host}:{args.port} asr_root={args.asr_root}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

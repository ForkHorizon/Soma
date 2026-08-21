#!/usr/bin/env python3
"""The job queue worker and retention sweep for Soma Voice Server.

One worker thread decodes one job at a time — the ASR backend holds a single
model, so there is nothing to gain from decoding in parallel. Priority ordering
(live dictation ahead of media imports) is applied when jobs are enqueued.

Free functions taking the `VoiceServerState`, so the state object stays the
single owner of the lock.
"""

from __future__ import annotations

import os
import tempfile
import threading
import time
import uuid
from typing import TYPE_CHECKING, Any

import voice_session_view
import voice_transcript_merge as merge
from voice_models import Job, PathologicalRepetitionError

if TYPE_CHECKING:  # annotations stay lazy, so this cannot cycle at runtime
    from voice_server import VoiceServerState  # noqa: F401


def spill_audio(body: bytes, suffix: str) -> str:
    """Put the upload on disk and return its path.

    Deliberately callable without the state lock: this is the only slow step in
    accepting a chunk, and holding the global lock across it stalls every other
    upload, long-poll wake-up and status read on the server.
    """
    fd, path = tempfile.mkstemp(prefix="soma-voice-", suffix=suffix)
    with os.fdopen(fd, "wb") as handle:
        handle.write(body)
    return path


def discard_audio(path: str) -> None:
    """Drop a spilled upload that was never accepted."""
    try:
        os.remove(path)
    except OSError:
        pass


def new_job(
    state,
    client_id: str,
    request_id: str,
    engine: str,
    language: str,
    idle_seconds: int,
    audio_path: str,
    work_class: str,
    client_managed_recovery: bool = False,
) -> Job:
    return Job(
        id=str(uuid.uuid4()),
        client_id=client_id,
        request_id=request_id,
        engine=engine,
        language=language,
        audio_path=audio_path,
        idle_seconds=max(0, idle_seconds),
        work_class=work_class,
        client_managed_recovery=client_managed_recovery,
    )


def submit(state, headers: dict[str, str], body: bytes) -> tuple[int, dict[str, Any]]:
    if len(body) > state.max_audio_bytes:
        return state.error(413, "audio_too_large", "Audio file is too large.", retryable=False)
    client_id, request_id, engine, idle_seconds = state._request_options(headers)
    if engine is None:
        return state.error(400, "unknown_engine", "Unknown ASR engine.", retryable=False)
    work_class = state._work_class(headers)
    if work_class is None:
        return state.error(400, "bad_work_class", "Work class must be interactive or background.", retryable=False)
    language = state._language(headers)
    if language is None:
        return state.error(400, "bad_language", "ASR language must be auto or an ISO language code.", retryable=False)
    suffix = state._audio_suffix(headers)
    if suffix is None:
        return state.error(415, "unsupported_audio", "Only WAV and FLAC audio are accepted.", retryable=False)
    key = (client_id, request_id)
    # Spilled before the lock: see voice_jobs.spill_audio.
    audio_path = spill_audio(body, suffix)
    accepted = False
    try:
        with state.changed:
            existing = state.idempotency.get(key)
            if existing and existing in state.jobs:
                return 202, state.jobs[existing].public()
            if error := state._queue_error_locked(work_class):
                return error
            job = state._new_job(client_id, request_id, engine, language, idle_seconds, audio_path, work_class)
            state.jobs[job.id] = job
            state.idempotency[key] = job.id
            state._enqueue_locked(job)
            state.changed.notify_all()
            accepted = True
            return 202, job.public()
    finally:
        if not accepted:
            discard_audio(audio_path)


def _decode(state, job: Job, initial_prompt: str | None) -> tuple[str, dict]:
    """Decode one job. Background work gets one retry without the text prompt
    before a decoder loop is treated as fatal."""
    result = state.broker.transcribe(job.engine, job.audio_path, job.idle_seconds, initial_prompt, job.language)
    text = str(result.get("text") or "").strip()
    if job.work_class != "background" or not merge.has_pathological_repetition(text):
        return text, result
    if job.client_managed_recovery:
        raise PathologicalRepetitionError("pathological_repetition")
    result = state.broker.transcribe(job.engine, job.audio_path, job.idle_seconds, None, job.language)
    text = str(result.get("text") or "").strip()
    if merge.has_pathological_repetition(text):
        raise PathologicalRepetitionError("pathological_repetition")
    return text, result


def _start_locked(state, job_id: str) -> tuple[Job, str | None] | None:
    job = state.jobs.get(job_id)
    if not job or job.status == "canceled":
        return None
    job.status = "running"
    job.started_at = time.time()
    job.queued_seconds = round(job.started_at - job.created_at, 2)
    initial_prompt = voice_session_view.prompt_locked(state, job)
    state.changed.notify_all()
    return job, initial_prompt


def _finish_locked(state, job: Job, text: str, result: dict) -> None:
    session = state.sessions.get(job.session_id) if job.session_id else None
    if job.status == "canceled" or (session and session.canceled):
        job.status = "canceled"
    else:
        job.text = text
        job.infer_seconds = result.get("infer_seconds")
        job.status = "done"
    job.finished_at = time.time()
    if session:
        voice_session_view.refresh_locked(state, session)
    state.changed.notify_all()


def _fail_locked(state, job: Job | None, exc: Exception) -> None:
    if job:
        session = state.sessions.get(job.session_id) if job.session_id else None
        if job.status != "canceled" and not (session and session.canceled):
            job.status = "failed"
            code = "pathological_repetition" if isinstance(exc, PathologicalRepetitionError) else "transcription_failed"
            job.error = {"code": code, "message": str(exc), "retryable": True}
        job.finished_at = time.time()
        if session:
            voice_session_view.refresh_locked(state, session)
    state.changed.notify_all()


def work_loop(state) -> None:
    while True:
        _priority, _sequence, job_id = state.pending.get()
        job: Job | None = None
        try:
            with state.changed:
                started = _start_locked(state, job_id)
                if started is None:
                    continue
                job, initial_prompt = started
            text, result = _decode(state, job, initial_prompt)
            with state.changed:
                _finish_locked(state, job, text, result)
        except Exception as exc:
            with state.changed:
                _fail_locked(state, job, exc)
        finally:
            if job:
                try:
                    os.remove(job.audio_path)
                except FileNotFoundError:
                    pass
            state.pending.task_done()


PRUNE_INTERVAL_SECONDS = 60.0


def start_pruner(state) -> threading.Thread:
    """Sweep expired jobs and sessions on a timer.

    This used to run at the top of every submit, get and chunk upload, taking
    the global lock for an O(jobs + sessions) scan on the hot path to expire
    things whose TTLs are measured in hours.
    """

    def loop() -> None:
        while True:
            time.sleep(PRUNE_INTERVAL_SECONDS)
            try:
                prune(state)
            except Exception:  # a sweep failure must never kill the sweeper
                pass

    thread = threading.Thread(target=loop, name="voice-prune", daemon=True)
    thread.start()
    return thread


def prune(state) -> None:
    cutoff = time.time() - state.completed_ttl
    abandoned_cutoff = time.time() - state.abandoned_session_ttl
    with state.changed:
        expired_jobs = [
            job_id for job_id, job in state.jobs.items() if job.finished_at is not None and job.finished_at < cutoff
        ]
        for job_id in expired_jobs:
            job = state.jobs.pop(job_id, None)
            if job:
                state.idempotency.pop((job.client_id, job.request_id), None)
        expired_sessions = [
            session_id
            for session_id, session in state.sessions.items()
            if session.status in {"done", "failed", "canceled"} and session.updated_at < cutoff
        ]
        for session_id in expired_sessions:
            session = state.sessions.pop(session_id, None)
            if session:
                state.session_idempotency.pop((session.client_id, session.request_id), None)
        abandoned_sessions = [
            session_id
            for session_id, session in state.sessions.items()
            if session.status in {"recording", "finalizing"} and session.updated_at < abandoned_cutoff
        ]
        for session_id in abandoned_sessions:
            session = state.sessions.get(session_id)
            if not session:
                continue
            session.canceled = True
            session.status = "canceled"
            for chunk in session.chunks.values():
                job = state.jobs.get(chunk.job_id)
                if job and job.status in {"queued", "running"}:
                    job.status = "canceled"
                    job.error = {"code": "session_expired", "message": "Voice session expired.", "retryable": True}
            state.sessions.pop(session_id, None)
            state.session_idempotency.pop((session.client_id, session.request_id), None)

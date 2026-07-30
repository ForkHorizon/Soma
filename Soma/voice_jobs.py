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
import time
import uuid
from typing import TYPE_CHECKING

import voice_session_view
import voice_transcript_merge as merge
from voice_models import Job, PathologicalRepetitionError

if TYPE_CHECKING:  # annotations stay lazy, so this cannot cycle at runtime
    from voice_server import VoiceServerState  # noqa: F401

def new_job(state, client_id: str, request_id: str, engine: str, language: str, idle_seconds: int, body: bytes, work_class: str, suffix: str, client_managed_recovery: bool = False) -> Job:
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


def prune(state) -> None:
    cutoff = time.time() - state.completed_ttl
    abandoned_cutoff = time.time() - state.abandoned_session_ttl
    with state.changed:
        expired_jobs = [job_id for job_id, job in state.jobs.items() if job.finished_at is not None and job.finished_at < cutoff]
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




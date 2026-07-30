#!/usr/bin/env python3
"""Chunk-session lifecycle for Soma Voice Server.

A session is one recording: ordered chunks, each backed by its own job, merged
into a single transcript when finalized. These are free functions taking the
`VoiceServerState` so the state object stays the single owner of the lock; the
`_locked` suffix means the caller already holds `state.changed`.
"""
from __future__ import annotations

import time
import uuid
from typing import TYPE_CHECKING, Any

import voice_transcript_merge as merge
from voice_models import Job, SessionChunk, VoiceSession

if TYPE_CHECKING:  # annotations stay lazy, so this cannot cycle at runtime
    from voice_server import VoiceServerState  # noqa: F401


def create(state, headers: dict[str, str]) -> tuple[int, dict[str, Any]]:
    state._prune()
    client_id, request_id, engine, idle_seconds = state._request_options(headers)
    if engine is None:
        return state.error(400, "unknown_engine", "Unknown ASR engine.", retryable=False)
    language = state._language(headers)
    if language is None:
        return state.error(400, "bad_language", "ASR language must be auto or an ISO language code.", retryable=False)
    key = (client_id, request_id)
    with state.changed:
        existing = state.session_idempotency.get(key)
        if existing and existing in state.sessions:
            return 200, public_locked(state, state.sessions[existing])
        session = VoiceSession(
            id=str(uuid.uuid4()),
            client_id=client_id,
            request_id=request_id,
            engine=engine,
            language=language,
            idle_seconds=idle_seconds,
        )
        state.sessions[session.id] = session
        state.session_idempotency[key] = session.id
        state.changed.notify_all()
        return 201, public_locked(state, session)


def submit_chunk(
    state,
    session_id: str,
    index: int,
    headers: dict[str, str],
    body: bytes,
) -> tuple[int, dict[str, Any]]:
    state._prune()
    if len(body) > state.max_audio_bytes:
        return state.error(413, "audio_too_large", "Audio file is too large.", retryable=False)
    if index < 0:
        return state.error(400, "bad_chunk_index", "Chunk index must be non-negative.", retryable=False)
    client_id = headers.get("x-soma-client-id", "unknown").strip() or "unknown"
    request_id = headers.get("x-soma-request-id", "").strip()
    if not request_id:
        return state.error(400, "missing_request_id", "Chunk uploads require X-Soma-Request-ID.", retryable=False)
    work_class = state._work_class(headers)
    if work_class is None:
        return state.error(400, "bad_work_class", "Work class must be interactive or background.", retryable=False)
    suffix = state._audio_suffix(headers)
    if suffix is None:
        return state.error(415, "unsupported_audio", "Only WAV and FLAC audio are accepted.", retryable=False)
    reason = headers.get("x-soma-chunk-reason", "pause").strip().lower()
    if reason not in {"pause", "forced", "final"}:
        return state.error(400, "bad_chunk_reason", "Chunk reason must be pause, forced, or final.", retryable=False)
    finalize_with_chunk = headers.get("x-soma-finalize-session", "").strip() == "1"
    retry_failed_chunk = headers.get("x-soma-retry-failed-chunk", "").strip() == "1"
    client_managed_recovery = headers.get("x-soma-chunk-recovery", "").strip() == "client-v1"
    context_chunk_index: int | None = None
    context_value = headers.get("x-soma-context-chunk-index", "").strip()
    if context_value:
        try:
            context_chunk_index = int(context_value)
        except ValueError:
            return state.error(400, "bad_context_chunk", "Context chunk index must be an integer.", retryable=False)
        if context_chunk_index != index - 1:
            return state.error(400, "bad_context_chunk", "Context must be the immediately preceding chunk.", retryable=False)
    if finalize_with_chunk and reason != "final":
        return state.error(400, "bad_finalization", "Only a final chunk can finalize a session.", retryable=False)
    try:
        overlap = max(0, int(headers.get("x-soma-overlap-milliseconds", "0")))
        duration = max(0, int(headers.get("x-soma-chunk-duration-milliseconds", "0")))
    except ValueError:
        return state.error(400, "bad_chunk_metadata", "Chunk overlap and duration must be integers.", retryable=False)

    with state.changed:
        session = state.sessions.get(session_id)
        if not session:
            return state.error(404, "session_not_found", "Voice session was not found or expired.", retryable=False)
        if session.client_id != client_id:
            return state.error(403, "session_client_mismatch", "Voice session belongs to another client.", retryable=False)
        if session.canceled:
            return state.error(409, "session_canceled", "Voice session was canceled.", retryable=False)
        existing = session.chunks.get(index)
        if session.finalized and not existing:
            return state.error(409, "session_finalized", "Voice session has already been finalized.", retryable=False)
        if existing:
            existing_job = state.jobs.get(existing.job_id)
            if not existing_job:
                return state.error(409, "chunk_job_missing", "Chunk job is no longer available.", retryable=True)
            if existing.request_id == request_id or existing_job.status != "failed":
                return 202, state.jobs[existing.job_id].public()
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
        if error := state._queue_error_locked(work_class):
            return error
        job = state._new_job(
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
        state.jobs[job.id] = job
        state.idempotency[(session.client_id, request_id)] = job.id
        session.chunks[index] = SessionChunk(index, job.id, request_id, reason, overlap, duration, context_chunk_index)
        if not existing:
            session.next_chunk_index += 1
        if finalize_with_chunk:
            session.finalized = True
            refresh_locked(state, session)
        session.updated_at = time.time()
        state._enqueue_locked(job)
        state.changed.notify_all()
        return 202, job.public()


def finalize(state, session_id: str, headers: dict[str, str]) -> tuple[int, dict[str, Any]]:
    client_id = headers.get("x-soma-client-id", "unknown").strip() or "unknown"
    with state.changed:
        session = state.sessions.get(session_id)
        if not session:
            return state.error(404, "session_not_found", "Voice session was not found or expired.", retryable=False)
        if session.client_id != client_id:
            return state.error(403, "session_client_mismatch", "Voice session belongs to another client.", retryable=False)
        if session.canceled:
            return state.error(409, "session_canceled", "Voice session was canceled.", retryable=False)
        session.finalized = True
        session.updated_at = time.time()
        refresh_locked(state, session)
        state.changed.notify_all()
        return 200, public_locked(state, session)


def cancel(state, session_id: str, headers: dict[str, str]) -> tuple[int, dict[str, Any]]:
    client_id = headers.get("x-soma-client-id", "unknown").strip() or "unknown"
    with state.changed:
        session = state.sessions.get(session_id)
        if not session:
            return state.error(404, "session_not_found", "Voice session was not found or expired.", retryable=False)
        if session.client_id != client_id:
            return state.error(403, "session_client_mismatch", "Voice session belongs to another client.", retryable=False)
        session.canceled = True
        session.status = "canceled"
        session.updated_at = time.time()
        for chunk in session.chunks.values():
            job = state.jobs.get(chunk.job_id)
            if job and job.status in {"queued", "running"}:
                job.status = "canceled"
                job.error = {"code": "session_canceled", "message": "Voice session was canceled.", "retryable": False}
        state.changed.notify_all()
        return 200, public_locked(state, session)


def prompt_locked(state, job: Job) -> str | None:
    if not job.session_id or job.chunk_index is None or job.engine != "whisper":
        return None
    session = state.sessions.get(job.session_id)
    if not session:
        return None
    chunk = session.chunks.get(job.chunk_index)
    # Pause-separated chunks are independent phrases. Giving Whisper the
    # prior transcript there can make it echo that text, which the normal
    # append path correctly cannot treat as an audio overlap. Only forced
    # chunks intentionally replay audio and therefore need text context.
    if not chunk or chunk.reason != "forced":
        return None
    text, _safe = merge_locked(state, session, stop_before=job.chunk_index)
    words = text.split()
    return " ".join(words[-50:]) if words else None


def refresh_locked(state, session: VoiceSession) -> None:
    session.updated_at = time.time()
    if session.canceled:
        session.status = "canceled"
        return
    jobs = [state.jobs[chunk.job_id] for chunk in session.chunks.values() if chunk.job_id in state.jobs]
    failed = next((job for job in jobs if job.status == "failed"), None)
    if failed:
        session.status = "failed"
        session.error = failed.error or {"code": "transcription_failed", "message": "A chunk failed.", "retryable": True}
        return
    if session.finalized:
        if all(job.status == "done" for job in jobs):
            session.text, session.merge_safe = merge_locked(state, session)
            session.status = "done"
        else:
            session.status = "finalizing"
    else:
        session.status = "recording"


def public_locked(state, session: VoiceSession) -> dict[str, Any]:
    chunks = [session.chunks[index] for index in sorted(session.chunks)]
    jobs = [state.jobs.get(chunk.job_id) for chunk in chunks]
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


def merge_locked(state, session: VoiceSession, stop_before: int | None = None) -> tuple[str, bool]:
    text = ""
    safe = True
    for index in sorted(session.chunks):
        if stop_before is not None and index >= stop_before:
            break
        chunk = session.chunks[index]
        job = state.jobs.get(chunk.job_id)
        if not job or job.status != "done":
            continue
        incoming = " ".join(job.text.split())
        if not incoming:
            continue
        if chunk.context_chunk_index is not None:
            context = session.chunks.get(chunk.context_chunk_index)
            context_job = state.jobs.get(context.job_id) if context else None
            if not context_job or context_job.status != "done":
                safe = False
            else:
                incoming, stripped = merge.strip_context_prefix(context_job.text, incoming)
                safe = safe and stripped
        if not text:
            text = incoming
            continue
        if chunk.overlap_milliseconds > 0:
            text, matched = merge.join_overlap(text, incoming)
            safe = safe and matched
        else:
            text = f"{text} {incoming}".strip()
    return text, safe

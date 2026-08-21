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

import voice_jobs
import voice_session_view
from voice_models import SessionChunk, VoiceSession

if TYPE_CHECKING:  # annotations stay lazy, so this cannot cycle at runtime
    from voice_server import VoiceServerState  # noqa: F401


def create(state, headers: dict[str, str]) -> tuple[int, dict[str, Any]]:
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
            return 200, voice_session_view.public_locked(state, state.sessions[existing])
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
        return 201, voice_session_view.public_locked(state, session)


def _parse_chunk_request(
    state, index: int, headers: dict[str, str]
) -> tuple[dict[str, Any] | None, tuple[int, dict[str, Any]] | None]:
    """Validate the chunk headers. Returns (request, None) or (None, error)."""
    if index < 0:
        return None, state.error(400, "bad_chunk_index", "Chunk index must be non-negative.", retryable=False)
    request_id = headers.get("x-soma-request-id", "").strip()
    if not request_id:
        return None, state.error(400, "missing_request_id", "Chunk uploads require X-Soma-Request-ID.", retryable=False)
    work_class = state._work_class(headers)
    if work_class is None:
        return None, state.error(
            400, "bad_work_class", "Work class must be interactive or background.", retryable=False
        )
    suffix = state._audio_suffix(headers)
    if suffix is None:
        return None, state.error(415, "unsupported_audio", "Only WAV and FLAC audio are accepted.", retryable=False)
    reason = headers.get("x-soma-chunk-reason", "pause").strip().lower()
    if reason not in {"pause", "forced", "final"}:
        return None, state.error(
            400, "bad_chunk_reason", "Chunk reason must be pause, forced, or final.", retryable=False
        )
    finalize_with_chunk = headers.get("x-soma-finalize-session", "").strip() == "1"
    if finalize_with_chunk and reason != "final":
        return None, state.error(400, "bad_finalization", "Only a final chunk can finalize a session.", retryable=False)
    context_chunk_index: int | None = None
    context_value = headers.get("x-soma-context-chunk-index", "").strip()
    if context_value:
        try:
            context_chunk_index = int(context_value)
        except ValueError:
            return None, state.error(
                400, "bad_context_chunk", "Context chunk index must be an integer.", retryable=False
            )
        if context_chunk_index != index - 1:
            return None, state.error(
                400, "bad_context_chunk", "Context must be the immediately preceding chunk.", retryable=False
            )
    try:
        overlap = max(0, int(headers.get("x-soma-overlap-milliseconds", "0")))
        duration = max(0, int(headers.get("x-soma-chunk-duration-milliseconds", "0")))
    except ValueError:
        return None, state.error(
            400, "bad_chunk_metadata", "Chunk overlap and duration must be integers.", retryable=False
        )
    return {
        "client_id": headers.get("x-soma-client-id", "unknown").strip() or "unknown",
        "request_id": request_id,
        "work_class": work_class,
        "suffix": suffix,
        "reason": reason,
        "finalize_with_chunk": finalize_with_chunk,
        "retry_failed_chunk": headers.get("x-soma-retry-failed-chunk", "").strip() == "1",
        "client_managed_recovery": headers.get("x-soma-chunk-recovery", "").strip() == "client-v1",
        "context_chunk_index": context_chunk_index,
        "overlap": overlap,
        "duration": duration,
    }, None


def _existing_chunk_reply(state, session, index: int, request: dict[str, Any]):
    """Idempotent replay of an already-accepted chunk, or None to accept it."""
    existing = session.chunks.get(index)
    if not existing:
        return None
    existing_job = state.jobs.get(existing.job_id)
    if not existing_job:
        return state.error(409, "chunk_job_missing", "Chunk job is no longer available.", retryable=True)
    if existing.request_id == request["request_id"] or existing_job.status != "failed":
        return 202, existing_job.public()
    if not request["retry_failed_chunk"]:
        return 202, existing_job.public()
    return None


def _store_chunk_locked(
    state, session, index: int, request: dict[str, Any], audio_path: str
) -> tuple[int, dict[str, Any]]:
    job = state._new_job(
        session.client_id,
        request["request_id"],
        session.engine,
        session.language,
        session.idle_seconds,
        audio_path,
        request["work_class"],
        request["client_managed_recovery"],
    )
    job.session_id = session.id
    job.chunk_index = index
    state.jobs[job.id] = job
    state.idempotency[(session.client_id, request["request_id"])] = job.id
    first_time = index not in session.chunks
    session.chunks[index] = SessionChunk(
        index,
        job.id,
        request["request_id"],
        request["reason"],
        request["overlap"],
        request["duration"],
        request["context_chunk_index"],
    )
    if first_time:
        session.next_chunk_index += 1
    if request["finalize_with_chunk"]:
        session.finalized = True
        voice_session_view.refresh_locked(state, session)
    session.updated_at = time.time()
    state._enqueue_locked(job)
    state.changed.notify_all()
    return 202, job.public()


def submit_chunk(
    state, session_id: str, index: int, headers: dict[str, str], body: bytes
) -> tuple[int, dict[str, Any]]:
    if len(body) > state.max_audio_bytes:
        return state.error(413, "audio_too_large", "Audio file is too large.", retryable=False)
    request, error = _parse_chunk_request(state, index, headers)
    if error:
        return error
    # Spill the audio before taking the lock. Every millisecond the lock is held
    # here delays the next chunk reaching the queue, which is exactly the gap
    # between "chunk received" and "decode starts" that we are trying to close.
    audio_path = voice_jobs.spill_audio(body, request["suffix"])
    accepted = False
    try:
        with state.changed:
            session = state.sessions.get(session_id)
            if not session:
                return state.error(404, "session_not_found", "Voice session was not found or expired.", retryable=False)
            if session.client_id != request["client_id"]:
                return state.error(
                    403, "session_client_mismatch", "Voice session belongs to another client.", retryable=False
                )
            if session.canceled:
                return state.error(409, "session_canceled", "Voice session was canceled.", retryable=False)
            existing = session.chunks.get(index)
            if session.finalized and not existing:
                return state.error(
                    409, "session_finalized", "Voice session has already been finalized.", retryable=False
                )
            if replay := _existing_chunk_reply(state, session, index, request):
                return replay
            if not existing and index != session.next_chunk_index:
                return 409, {
                    "error": {
                        "code": "chunk_out_of_order",
                        "message": "Chunk index must be the next expected index.",
                        "retryable": True,
                    },
                    "expected_chunk_index": session.next_chunk_index,
                }
            if error := state._queue_error_locked(request["work_class"]):
                return error
            reply = _store_chunk_locked(state, session, index, request, audio_path)
            accepted = True
            return reply
    finally:
        if not accepted:
            voice_jobs.discard_audio(audio_path)


def finalize(state, session_id: str, headers: dict[str, str]) -> tuple[int, dict[str, Any]]:
    client_id = headers.get("x-soma-client-id", "unknown").strip() or "unknown"
    with state.changed:
        session = state.sessions.get(session_id)
        if not session:
            return state.error(404, "session_not_found", "Voice session was not found or expired.", retryable=False)
        if session.client_id != client_id:
            return state.error(
                403, "session_client_mismatch", "Voice session belongs to another client.", retryable=False
            )
        if session.canceled:
            return state.error(409, "session_canceled", "Voice session was canceled.", retryable=False)
        session.finalized = True
        session.updated_at = time.time()
        voice_session_view.refresh_locked(state, session)
        state.changed.notify_all()
        return 200, voice_session_view.public_locked(state, session)


def cancel(state, session_id: str, headers: dict[str, str]) -> tuple[int, dict[str, Any]]:
    client_id = headers.get("x-soma-client-id", "unknown").strip() or "unknown"
    with state.changed:
        session = state.sessions.get(session_id)
        if not session:
            return state.error(404, "session_not_found", "Voice session was not found or expired.", retryable=False)
        if session.client_id != client_id:
            return state.error(
                403, "session_client_mismatch", "Voice session belongs to another client.", retryable=False
            )
        session.canceled = True
        session.status = "canceled"
        session.updated_at = time.time()
        for chunk in session.chunks.values():
            job = state.jobs.get(chunk.job_id)
            if job and job.status in {"queued", "running"}:
                job.status = "canceled"
                job.error = {"code": "session_canceled", "message": "Voice session was canceled.", "retryable": False}
        state.changed.notify_all()
        return 200, voice_session_view.public_locked(state, session)

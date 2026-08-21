#!/usr/bin/env python3
"""Derived views over a voice session: status, public payload, merged text.

Everything here reads session and job state to compute something; nothing here
mutates a session's identity or queue. The `_locked` suffix means the caller
already holds `state.changed`.
"""

from __future__ import annotations

import time
from typing import Any

import voice_transcript_merge as merge
from voice_models import Job, VoiceSession


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
        session.error = failed.error or {
            "code": "transcription_failed",
            "message": "A chunk failed.",
            "retryable": True,
        }
        return
    if session.finalized:
        if all(job.status == "done" for job in jobs):
            session.text, session.merge_safe = merge_locked(state, session)
            session.status = "done"
        else:
            session.status = "finalizing"
    else:
        session.status = "recording"


def completed_locked(state, session: VoiceSession) -> int:
    """How many of the session's chunks have finished decoding."""
    return sum(1 for chunk in session.chunks.values() if (job := state.jobs.get(chunk.job_id)) and job.status == "done")


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
    elif completed:
        # Everything decoded so far. Measured on 30 real recordings: 86% of the
        # transcript (median) is already sitting here when the user releases the
        # key, because chunks decode while they are still speaking. Without this
        # the client cannot see any of it until the final merge.
        partial, _safe = merge_locked(state, session)
        if partial:
            data["partial_text"] = partial
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

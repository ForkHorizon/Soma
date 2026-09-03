#!/usr/bin/env python3
"""Engine-specific decoding for an ASR backend process.

Pure functions: the caller owns the loaded model and passes it in. Heavy imports
stay inside the functions so the module can be imported outside an engine venv.
Everything here runs on the backend's single model thread.
"""

from __future__ import annotations

import tempfile

GIGAAM_WINDOW_SECONDS = 20.0
GIGAAM_OVERLAP_SECONDS = 1.0


def transcribe_whisper(
    audio: str,
    repository: str,
    initial_prompt: str | None = None,
    language: str | None = None,
) -> str:
    import mlx_whisper
    import numpy as np
    import soundfile as sf

    data, sr = sf.read(audio, dtype="float32")
    if getattr(data, "ndim", 1) > 1:
        data = data.mean(axis=1)
    if sr != 16000:
        n = int(round(len(data) * 16000 / sr))
        data = np.interp(
            np.linspace(0, len(data), n, endpoint=False),
            np.arange(len(data)),
            data,
        ).astype(np.float32)
    options = {
        "path_or_hf_repo": repository,
        "initial_prompt": initial_prompt,
        "condition_on_previous_text": False,
    }
    # `None` deliberately omits the parameter: Whisper then identifies the
    # language from the audio. Normal recordings still arrive as `ru`.
    if language is not None:
        options["language"] = language
    result = mlx_whisper.transcribe(np.ascontiguousarray(data), **options)
    return (result.get("text") or "").strip()


def transcribe_gigaam(audio: str, model) -> str:
    import soundfile as sf

    data, sr = sf.read(audio)
    if getattr(data, "ndim", 1) > 1:
        data = data.mean(axis=1)
    if len(data) / sr <= GIGAAM_WINDOW_SECONDS:
        return transcription_text(model.transcribe(audio))

    win, overlap = int(GIGAAM_WINDOW_SECONDS * sr), int(GIGAAM_OVERLAP_SECONDS * sr)
    step, parts, start = win - overlap, [], 0
    while start < len(data):
        seg = data[start : start + win]
        if len(seg) < sr * 0.3:
            break
        with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
            sf.write(tmp.name, seg, sr)
            parts.append(transcription_text(model.transcribe(tmp.name)))
        if start + win >= len(data):
            break
        start += step
    return join_parts(parts)


def transcription_text(result) -> str:
    """Normalize string and GigaAM TranscriptionResult outputs."""
    if isinstance(result, str):
        return result
    return (
        getattr(result, "text", None)
        or " ".join(getattr(piece, "text", "") for piece in getattr(result, "pieces", []))
        or str(result)
    )


def join_parts(parts: list[str]) -> str:
    words: list[str] = []
    for part in parts:
        incoming = part.strip().split()
        if not incoming:
            continue
        max_overlap = min(len(words), len(incoming), 12)
        overlap = 0
        for count in range(max_overlap, 0, -1):
            if words[-count:] == incoming[:count]:
                overlap = count
                break
        words.extend(incoming[overlap:])
    return " ".join(words)

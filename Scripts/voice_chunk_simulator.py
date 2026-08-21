#!/usr/bin/env python3
"""Python port of the client-side chunker, for offline experiments.

Mirrors VoicePauseDetector and VoiceChunkCapture from Soma/VoiceChunkCapture.swift
so a saved recording can be split exactly the way the app would have split it
live. Chunk boundaries depend on detected speech, not wall time: a forced cut
only happens after 10s of *active* audio, so it lands mid-speech where the
replayed window actually contains words. Cutting on wall time instead makes the
overlap joins look far more fragile than they are.

`forced_seconds` is adjustable so the cut threshold can be swept against tail
latency. That sweep has been run (120 recordings, 2026-07-31) and the answer was
to leave it at 10s:

  forced cut   chunks/rec   final chunk   tail decode   total decode
        10s          3.5          5.4s         1.26s          5.6s   ships
         5s          6.5          3.0s         0.94s          7.6s   -0.32s
         3s         11.6          2.2s         0.84s         10.8s   -0.42s

At best it buys 0.42s while tripling the chunk count and doubling total decode
— and every extra chunk adds a forced seam, which fails to match 53% of the time
and now shows up as duplicated words. Cutting more often multiplies the one
defect the seam policy just made visible.
"""

from __future__ import annotations

SAMPLE_RATE = 16000


class PauseDetector:
    """Port of VoicePauseDetector (Soma/VoiceChunkCapture.swift).

    Chunk boundaries depend on detected speech, not wall time: a forced cut only
    happens after 10s of *active* audio, so it lands mid-speech where the replay
    window actually contains words. Cutting on wall time instead makes joins look
    far more fragile than they are.
    """

    def __init__(self, sample_rate: int = SAMPLE_RATE, forced_seconds: float = 10.0):
        self.sample_rate = sample_rate
        self.forced_seconds = forced_seconds
        self.noise_floor_db = -60.0
        self.speech_buffers = 0
        self.active = False
        self.active_frames = 0
        self.speech_frames = 0
        self.silence_frames = 0

    def reset(self) -> None:
        self.speech_buffers = 0
        self.active = False
        self.active_frames = 0
        self.speech_frames = 0
        self.silence_frames = 0

    def begin_forced_overlap(self) -> None:
        self.active = True
        self.speech_buffers = 2
        self.active_frames = int(self.sample_rate * 0.75)
        self.speech_frames = 0
        self.silence_frames = 0

    def observe(self, dbfs: float, frames: int) -> str:
        threshold = min(-30.0, max(-48.0, self.noise_floor_db + 12.0))
        speech = dbfs >= threshold
        if not self.active:
            if speech:
                self.speech_buffers += 1
                if self.speech_buffers >= 2:
                    self.active = True
                    self.active_frames = frames * self.speech_buffers
                    self.speech_frames = self.active_frames
                    self.silence_frames = 0
                    return "speech_started"
            else:
                self.speech_buffers = 0
                self.noise_floor_db = max(-80.0, min(-20.0, self.noise_floor_db * 0.95 + dbfs * 0.05))
            return "none"
        self.active_frames += frames
        if speech:
            self.speech_frames += frames
            self.silence_frames = 0
        else:
            self.silence_frames += frames
        if self.active_frames >= int(self.sample_rate * self.forced_seconds):
            self.reset()
            return "forced"
        if self.active_frames >= int(self.sample_rate * 2.5) and self.silence_frames >= int(self.sample_rate * 0.65):
            self.reset()
            return "pause"
        return "none"


def level_dbfs(block) -> float:
    import numpy as np

    if len(block) == 0:
        return -80.0
    rms = float(np.sqrt(np.mean(np.square(block.astype(np.float64)))))
    return max(-80.0, 20.0 * np.log10(max(rms, 1e-7)))


def capture_chunks(audio, block_frames: int = 1024, forced_seconds: float = 10.0) -> list[dict]:
    """Replays VoiceChunkCapture: same replay windows, reasons and overlaps."""
    detector = PauseDetector(forced_seconds=forced_seconds)
    chunks: list[dict] = []
    open_start: int | None = None
    reason = "pause"
    overlap_ms = 0

    def start(position: int, replay_seconds: float, new_reason: str, new_overlap: int) -> int:
        nonlocal reason, overlap_ms
        reason, overlap_ms = new_reason, new_overlap
        return max(0, position - int(replay_seconds * SAMPLE_RATE))

    def seal(position: int, seal_reason: str) -> None:
        nonlocal open_start
        if open_start is None or position <= open_start:
            open_start = None
            return
        chunks.append(
            {
                "start": open_start,
                "end": position,
                "reason": seal_reason if reason == "pause" else reason,
                "overlap_ms": overlap_ms,
            }
        )
        open_start = None

    for offset in range(0, len(audio), block_frames):
        block = audio[offset : offset + block_frames]
        event = detector.observe(level_dbfs(block), len(block))
        position = offset + len(block)
        if event == "speech_started":
            open_start = start(offset, 0.25, "pause", 0)
        elif event == "pause":
            seal(position, "pause")
        elif event == "forced":
            seal(position, "forced")
            open_start = start(position, 0.75, "forced", 750)
            detector.begin_forced_overlap()
    if open_start is not None and detector.speech_frames >= int(SAMPLE_RATE * 0.25):
        seal(len(audio), "final")
    return chunks

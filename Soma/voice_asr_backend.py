#!/usr/bin/env python3
"""Warm ASR backend for one Soma Voice Server engine.

This process runs inside the selected engine venv. The public network server
never imports Whisper/GigaAM directly; it forwards local temp WAV paths here.
"""
from __future__ import annotations

import gc
import json
import os
import sys
import tempfile
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ENGINE = (os.environ.get("ASR_ENGINE") or "whisper").strip().lower()
LANG = os.environ.get("ASR_LANG", "ru")
WHISPER_REPO = os.environ.get("ASR_WHISPER_REPO", "mlx-community/whisper-large-v3-mlx")
GIGAAM_ROOT = os.environ.get("ASR_GIGAAM_ROOT", "")
GIGAAM_MODEL = os.environ.get("ASR_GIGAAM_MODEL", "rnnt")

_lock = threading.Lock()
_model = None
_loaded = False
_last_used = time.monotonic()
_idle_seconds = max(0.0, float(os.environ.get("ASR_IDLE_SECONDS", "3600")))


def _health() -> dict:
    return {
        "ok": True,
        "engine": ENGINE,
        "loaded": _loaded,
        "idle_seconds": _idle_seconds,
        "last_used_seconds_ago": round(time.monotonic() - _last_used, 1) if _loaded else None,
    }


def _load() -> None:
    global _model, _loaded
    if _loaded:
        return
    if ENGINE == "whisper":
        import mlx.core as mx
        from mlx_whisper.transcribe import ModelHolder

        # mlx_whisper.transcribe owns the cache actually used during decoding.
        # Loading through load_models.load_model here used to create a second
        # model that the next transcription did not reuse.
        ModelHolder.get_model(WHISPER_REPO, mx.float16)
    elif ENGINE == "gigaam":
        import gigaam

        _model = gigaam.load_model(GIGAAM_MODEL, device="cpu", download_root=GIGAAM_ROOT or None)
    else:
        raise ValueError(f"unknown ASR_ENGINE: {ENGINE!r}")
    _loaded = True


def _unload() -> None:
    global _model, _loaded
    if not _loaded:
        return
    if ENGINE == "whisper":
        try:
            from mlx_whisper.transcribe import ModelHolder

            ModelHolder.model = None
            ModelHolder.model_path = None
        except Exception:
            pass
    _model = None
    _loaded = False
    gc.collect()
    try:
        import mlx.core as mx

        mx.clear_cache()
    except Exception:
        pass


def _transcribe_whisper(audio: str, initial_prompt: str | None = None) -> str:
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
    result = mlx_whisper.transcribe(
        np.ascontiguousarray(data),
        path_or_hf_repo=WHISPER_REPO,
        language=LANG,
        initial_prompt=initial_prompt,
    )
    return (result.get("text") or "").strip()


def _transcribe_gigaam(audio: str) -> str:
    import soundfile as sf

    data, sr = sf.read(audio)
    if getattr(data, "ndim", 1) > 1:
        data = data.mean(axis=1)
    dur = len(data) / sr
    if dur <= 20.0:
        return (_model.transcribe(audio) or "").strip()

    win, overlap = int(20.0 * sr), int(1.0 * sr)
    step, parts, start = win - overlap, [], 0
    while start < len(data):
        seg = data[start : start + win]
        if len(seg) < sr * 0.3:
            break
        with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
            sf.write(tmp.name, seg, sr)
            parts.append(_model.transcribe(tmp.name))
        if start + win >= len(data):
            break
        start += step
    return _join_parts(parts)


def _join_parts(parts: list[str]) -> str:
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


def _transcribe(audio: str, initial_prompt: str | None = None) -> str:
    if ENGINE == "whisper":
        return _transcribe_whisper(audio, initial_prompt)
    return _transcribe_gigaam(audio)


class BackendHTTPServer(HTTPServer):
    """Keep all MLX model operations on the server's one request thread.

    MLX streams are thread-affine. A threaded HTTP server can load the model for
    `/warmup` on one worker and decode `/transcribe` on another, leaving the
    cached model attached to the wrong stream. `service_actions` also performs
    idle unloads on that same thread.
    """

    def service_actions(self) -> None:
        with _lock:
            if _loaded and _idle_seconds > 0 and (time.monotonic() - _last_used) > _idle_seconds:
                _unload()


class Handler(BaseHTTPRequestHandler):
    def _reply(self, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/health":
            self._reply(200, _health())
        else:
            self._reply(404, {"error": "not found"})

    def do_POST(self) -> None:
        global _idle_seconds, _last_used
        if self.path == "/configure":
            try:
                req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
                if "idle_seconds" in req:
                    _idle_seconds = max(0.0, float(req["idle_seconds"]))
                    if _idle_seconds == 0:
                        with _lock:
                            _unload()
                self._reply(200, _health())
            except Exception as exc:
                self._reply(400, {"error": f"bad request: {exc}"})
            return
        if self.path == "/warmup":
            try:
                req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
                if "idle_seconds" in req:
                    _idle_seconds = max(0.0, float(req["idle_seconds"]))
                with _lock:
                    already_loaded = _loaded
                    t0 = time.perf_counter()
                    _load()
                    load_seconds = time.perf_counter() - t0
                    _last_used = time.monotonic()
                self._reply(200, {
                    "ok": True,
                    "engine": ENGINE,
                    "loaded": True,
                    "already_loaded": already_loaded,
                    "load_seconds": round(load_seconds, 2),
                })
            except Exception as exc:
                traceback.print_exc()
                self._reply(500, {"error": str(exc), "engine": ENGINE})
            return
        if self.path != "/transcribe":
            self._reply(404, {"error": "not found"})
            return
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        except Exception as exc:
            self._reply(400, {"error": f"bad request: {exc}"})
            return

        audio = req.get("audio")
        if not audio or not Path(audio).exists():
            self._reply(400, {"error": f"audio not found: {audio}"})
            return
        if "idle_seconds" in req:
            _idle_seconds = max(0.0, float(req["idle_seconds"]))
        initial_prompt = req.get("initial_prompt")
        if not isinstance(initial_prompt, str):
            initial_prompt = None

        with _lock:
            try:
                _load()
                t0 = time.perf_counter()
                text = _transcribe(audio, initial_prompt)
                elapsed = time.perf_counter() - t0
                _last_used = time.monotonic()
                self._reply(200, {"text": text.strip(), "engine": ENGINE, "infer_seconds": round(elapsed, 2)})
                if _idle_seconds == 0:
                    _unload()
            except Exception as exc:
                traceback.print_exc()
                self._reply(500, {"error": str(exc), "engine": ENGINE})

    def log_message(self, *_args) -> None:
        pass


def main() -> None:
    if ENGINE not in {"whisper", "gigaam"}:
        print(f"[soma-voice-backend] unknown ASR_ENGINE={ENGINE!r}", flush=True)
        sys.exit(2)
    port = int(os.environ.get("ASR_PORT", "0"))
    server = BackendHTTPServer(("127.0.0.1", port), Handler)
    actual = server.server_address[1]
    port_file = os.environ.get("ASR_PORT_FILE")
    if port_file:
        Path(port_file).write_text(str(actual), encoding="utf-8")
    print(f"[soma-voice-backend] engine={ENGINE} port={actual} idle={_idle_seconds}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Warm ASR backend for one Soma Voice Server engine.

This process runs inside the selected engine venv. The public network server
never imports Whisper/GigaAM directly; it forwards local temp WAV paths here.
"""
from __future__ import annotations

import gc
import json
import os
import queue
import sys
import tempfile
import threading
import time
import traceback
from concurrent.futures import Future
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ENGINE = (os.environ.get("ASR_ENGINE") or "whisper").strip().lower()
LANG = os.environ.get("ASR_LANG", "ru")
WHISPER_REPO = os.environ.get("ASR_WHISPER_REPO", "mlx-community/whisper-large-v3-mlx")
GIGAAM_ROOT = os.environ.get("ASR_GIGAAM_ROOT", "")
GIGAAM_MODEL = os.environ.get("ASR_GIGAAM_MODEL", "rnnt")

_model = None
_loaded = False
_busy = False
_last_used = time.monotonic()
_idle_seconds = max(0.0, float(os.environ.get("ASR_IDLE_SECONDS", "3600")))

# Every MLX operation runs on this one thread; HTTP handler threads only submit
# work to it. MLX streams are thread-affine, so load/decode/unload must share a
# thread — but nothing else has to wait behind them.
_MODEL_TICK_SECONDS = 1.0
_work: queue.Queue = queue.Queue()
_worker_lock = threading.Lock()
_worker: threading.Thread | None = None


def _model_loop() -> None:
    global _busy
    while True:
        try:
            job, future = _work.get(timeout=_MODEL_TICK_SECONDS)
        except queue.Empty:
            if _loaded and _idle_seconds > 0 and (time.monotonic() - _last_used) > _idle_seconds:
                _unload()
            continue
        if not future.set_running_or_notify_cancel():
            continue
        _busy = True
        try:
            future.set_result(job())
        except Exception as exc:
            future.set_exception(exc)
        finally:
            _busy = False


def _submit(job) -> Future:
    """Queue `job` for the model thread, starting that thread on first use."""
    global _worker
    with _worker_lock:
        if _worker is None or not _worker.is_alive():
            _worker = threading.Thread(target=_model_loop, name="asr-model", daemon=True)
            _worker.start()
    future: Future = Future()
    _work.put((job, future))
    return future


def _on_model_thread(job):
    return _submit(job).result()


def _health() -> dict:
    return {
        "ok": True,
        "engine": ENGINE,
        "loaded": _loaded,
        "busy": _busy,
        "queue_depth": _work.qsize(),
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


def _transcribe_whisper(
    audio: str,
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
        "path_or_hf_repo": WHISPER_REPO,
        "initial_prompt": initial_prompt,
    }
    # `None` deliberately omits the parameter: Whisper then identifies the
    # language from the audio. Normal recordings still arrive as `ru`.
    if language is not None:
        options["language"] = language
    result = mlx_whisper.transcribe(np.ascontiguousarray(data), **options)
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


def _transcribe(
    audio: str,
    initial_prompt: str | None = None,
    language: str | None = None,
) -> str:
    if ENGINE == "whisper":
        return _transcribe_whisper(audio, initial_prompt, language)
    return _transcribe_gigaam(audio)


def _requested_language(request: dict) -> str | None:
    language = request.get("language", LANG)
    if not isinstance(language, str):
        raise ValueError("language must be a string or auto")
    return None if language == "auto" else language


def _warm_job() -> dict:
    global _last_used
    already_loaded = _loaded
    t0 = time.perf_counter()
    _load()
    _last_used = time.monotonic()
    return {
        "ok": True,
        "engine": ENGINE,
        "loaded": True,
        "already_loaded": already_loaded,
        "load_seconds": round(time.perf_counter() - t0, 2),
    }


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
                        _submit(_unload)
                self._reply(200, _health())
            except Exception as exc:
                self._reply(400, {"error": f"bad request: {exc}"})
            return
        if self.path == "/warmup":
            try:
                req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
                if "idle_seconds" in req:
                    _idle_seconds = max(0.0, float(req["idle_seconds"]))
                if _loaded:
                    # Record-start fires this on every recording. A warm model
                    # must answer immediately, never behind an in-flight decode.
                    _last_used = time.monotonic()
                    self._reply(200, {
                        "ok": True,
                        "engine": ENGINE,
                        "loaded": True,
                        "already_loaded": True,
                        "load_seconds": 0.0,
                    })
                    return
                self._reply(200, _on_model_thread(_warm_job))
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
        # The server's default remains Russian for live dictation. A media
        # import explicitly sends "auto", which must be forwarded as None so
        # Whisper uses its language detector instead of that default.
        try:
            language = _requested_language(req)
        except ValueError as exc:
            self._reply(400, {"error": str(exc)})
            return

        def job() -> dict:
            global _last_used
            _load()
            t0 = time.perf_counter()
            text = _transcribe(audio, initial_prompt, language)
            elapsed = time.perf_counter() - t0
            _last_used = time.monotonic()
            return {"text": text.strip(), "engine": ENGINE, "infer_seconds": round(elapsed, 2)}

        try:
            result = _on_model_thread(job)
        except Exception as exc:
            traceback.print_exc()
            self._reply(500, {"error": str(exc), "engine": ENGINE})
            return
        self._reply(200, result)
        if _idle_seconds == 0:
            _submit(_unload)

    def log_message(self, *_args) -> None:
        pass


def main() -> None:
    if ENGINE not in {"whisper", "gigaam"}:
        print(f"[soma-voice-backend] unknown ASR_ENGINE={ENGINE!r}", flush=True)
        sys.exit(2)
    port = int(os.environ.get("ASR_PORT", "0"))
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    actual = server.server_address[1]
    port_file = os.environ.get("ASR_PORT_FILE")
    if port_file:
        Path(port_file).write_text(str(actual), encoding="utf-8")
    print(f"[soma-voice-backend] engine={ENGINE} port={actual} idle={_idle_seconds}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

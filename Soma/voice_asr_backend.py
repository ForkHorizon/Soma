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
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import voice_asr_engines
import voice_asr_worker
from voice_asr_engines import join_parts as _join_parts  # noqa: F401  (re-exported for tests)
from voice_asr_worker import run as _on_model_thread, submit as _submit

ENGINE = (os.environ.get("ASR_ENGINE") or "whisper").strip().lower()
LANG = os.environ.get("ASR_LANG", "ru")
WHISPER_REPO = os.environ.get("ASR_WHISPER_REPO", "mlx-community/whisper-large-v3-mlx")
GIGAAM_ROOT = os.environ.get("ASR_GIGAAM_ROOT", "")
GIGAAM_MODEL = os.environ.get("ASR_GIGAAM_MODEL", "rnnt")

_model = None
_loaded = False
_last_used = time.monotonic()
_idle_seconds = max(0.0, float(os.environ.get("ASR_IDLE_SECONDS", "3600")))


def _unload_when_idle() -> None:
    """Runs on the model thread between jobs, so the unload stays thread-affine."""
    if _loaded and _idle_seconds > 0 and (time.monotonic() - _last_used) > _idle_seconds:
        _unload()


voice_asr_worker.configure(_unload_when_idle)


def _health() -> dict:
    return {
        "ok": True,
        "engine": ENGINE,
        "loaded": _loaded,
        "busy": voice_asr_worker.busy(),
        "queue_depth": voice_asr_worker.depth(),
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


def _transcribe(
    audio: str,
    initial_prompt: str | None = None,
    language: str | None = None,
) -> str:
    if ENGINE == "whisper":
        return voice_asr_engines.transcribe_whisper(audio, WHISPER_REPO, initial_prompt, language)
    return voice_asr_engines.transcribe_gigaam(audio, _model)


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

    def _request_body(self) -> dict:
        return json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")

    def do_POST(self) -> None:
        route = {
            "/configure": self._post_configure,
            "/warmup": self._post_warmup,
            "/transcribe": self._post_transcribe,
        }.get(self.path)
        if route is None:
            self._reply(404, {"error": "not found"})
            return
        route()

    def _post_configure(self) -> None:
        global _idle_seconds
        try:
            req = self._request_body()
            if "idle_seconds" in req:
                _idle_seconds = max(0.0, float(req["idle_seconds"]))
                if _idle_seconds == 0:
                    _submit(_unload)
            self._reply(200, _health())
        except Exception as exc:
            self._reply(400, {"error": f"bad request: {exc}"})

    def _post_warmup(self) -> None:
        global _idle_seconds, _last_used
        try:
            req = self._request_body()
            if "idle_seconds" in req:
                _idle_seconds = max(0.0, float(req["idle_seconds"]))
            if _loaded:
                # Record-start fires this on every recording. A warm model must
                # answer immediately, never behind an in-flight decode.
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

    def _post_transcribe(self) -> None:
        global _idle_seconds
        try:
            req = self._request_body()
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

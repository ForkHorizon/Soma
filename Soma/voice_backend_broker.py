#!/usr/bin/env python3
"""Owns the warm per-engine ASR backend subprocess for Soma Voice Server.

The network server never imports Whisper/GigaAM. It hands local audio paths to
the backend through this broker, which starts the right engine venv on demand
and reports backend health without ever blocking a request thread.
"""
from __future__ import annotations

import json
import os
import subprocess
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

ENGINES = {
    "whisper": "Whisper large-v3",
    "gigaam": "GigaAM v2 (Russian)",
}

BACKEND_HEALTH_REFRESH_SECONDS = 2.0
BACKEND_HEALTH_IDLE_STOP_SECONDS = 60.0
BACKEND_WARMUP_TIMEOUT_SECONDS = 90


class BackendBroker:
    def __init__(self, asr_root: Path, runtime_dir: Path, idle_seconds: int, models_root: Path | None = None):
        self.asr_root = asr_root.expanduser()
        self.runtime_dir = runtime_dir.expanduser()
        self.idle_seconds = idle_seconds
        self.models_root = models_root.expanduser() if models_root else self.asr_root / "asr-models"
        self.script = Path(__file__).with_name("voice_asr_backend.py")
        self.process: subprocess.Popen[str] | None = None
        self.engine: str | None = None
        self.port: int | None = None
        self.lock = threading.Lock()
        self._health_lock = threading.Lock()
        self._health_snapshot: dict[str, Any] = {}
        self._health_taken_at = 0.0
        self._health_key: tuple[str | None, int | None] = (None, None)
        self._health_thread: threading.Thread | None = None
        self._health_wake = threading.Event()
        self._health_wanted_at = 0.0

    def health(self) -> dict[str, Any]:
        """Never performs backend I/O. A request thread must not be able to
        block behind a decode just to report status."""
        engine, port = self.engine, self.port
        running = bool(self.process and self.process.poll() is None)
        data: dict[str, Any] = {
            "active_engine": engine,
            "active_port": port,
            "backend_running": running,
            "backend_loaded": False,
            "backend_idle_seconds": None,
            "backend_last_used_seconds_ago": None,
            "backend_health_age_seconds": None,
        }
        if not (running and port):
            return data
        self._start_health_refresh()
        with self._health_lock:
            fresh = self._health_key == (engine, port)
            snapshot = dict(self._health_snapshot) if fresh else {}
            taken_at = self._health_taken_at
        if snapshot:
            data.update(snapshot)
            data["backend_health_age_seconds"] = round(time.monotonic() - taken_at, 1)
        return data

    def _start_health_refresh(self) -> None:
        with self._health_lock:
            self._health_wanted_at = time.monotonic()
            if self._health_thread is not None:
                return
            self._health_thread = threading.Thread(target=self._health_loop, name="backend-health", daemon=True)
            self._health_thread.start()

    def _health_loop(self) -> None:
        # Starting and stopping are both decided under _health_lock, so a caller
        # can never observe a live thread that is about to exit.
        try:
            while True:
                engine, port = self.engine, self.port
                running = bool(self.process and self.process.poll() is None)
                snapshot: dict[str, Any] = {}
                if running and port:
                    try:
                        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=5) as response:
                            health = json.loads(response.read().decode())
                        snapshot = {
                            "backend_loaded": bool(health.get("loaded")),
                            "backend_busy": bool(health.get("busy")),
                            "backend_queue_depth": health.get("queue_depth"),
                            "backend_idle_seconds": health.get("idle_seconds"),
                            "backend_last_used_seconds_ago": health.get("last_used_seconds_ago"),
                        }
                    except Exception as exc:
                        snapshot = {"backend_error": str(exc)}
                with self._health_lock:
                    self._health_snapshot = snapshot
                    self._health_taken_at = time.monotonic()
                    self._health_key = (engine, port)
                    if time.monotonic() - self._health_wanted_at > BACKEND_HEALTH_IDLE_STOP_SECONDS:
                        return
                self._health_wake.wait(BACKEND_HEALTH_REFRESH_SECONDS)
                self._health_wake.clear()
        finally:
            with self._health_lock:
                self._health_thread = None

    def _running_port(self, engine: str) -> int | None:
        if self.engine == engine and self.port and self.process and self.process.poll() is None:
            return self.port
        return None

    def configure(self, idle_seconds: int) -> None:
        self.idle_seconds = max(0, int(idle_seconds))
        if not (self.process and self.process.poll() is None and self.port):
            return
        payload = json.dumps({"idle_seconds": self.idle_seconds}).encode()
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/configure",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as response:
            response.read()

    def warm(self, engine: str, idle_seconds: int | None = None) -> dict[str, Any]:
        if engine not in ENGINES:
            raise RuntimeError(f"unknown_engine:{engine}")
        effective_idle = self.idle_seconds if idle_seconds is None else idle_seconds
        payload = {"idle_seconds": effective_idle}
        # Record-start fires warmup on every recording. When the backend for this
        # engine is already up, skip self.lock entirely: an in-flight transcribe
        # holds it for its whole decode, and the backend answers an already-warm
        # /warmup off its model thread.
        if port := self._running_port(engine):
            return self._post_backend(port, "/warmup", payload, timeout=BACKEND_WARMUP_TIMEOUT_SECONDS)
        with self.lock:
            port = self._ensure_backend(engine, effective_idle)
            return self._post_backend(port, "/warmup", payload, timeout=BACKEND_WARMUP_TIMEOUT_SECONDS)

    def transcribe(
        self,
        engine: str,
        audio_path: str,
        idle_seconds: int | None = None,
        initial_prompt: str | None = None,
        language: str = "ru",
    ) -> dict[str, Any]:
        if engine not in ENGINES:
            raise RuntimeError(f"unknown_engine:{engine}")
        with self.lock:
            effective_idle = self.idle_seconds if idle_seconds is None else idle_seconds
            port = self._ensure_backend(engine, effective_idle)
            payload: dict[str, Any] = {"audio": audio_path, "idle_seconds": effective_idle, "language": language}
            if initial_prompt:
                payload["initial_prompt"] = initial_prompt
            return self._post_backend(port, "/transcribe", payload, timeout=900)

    @staticmethod
    def _post_backend(port: int, path: str, payload: dict[str, Any], timeout: int = 30) -> dict[str, Any]:
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}{path}",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                body = response.read()
        except urllib.error.HTTPError as exc:
            body = exc.read()
            try:
                obj = json.loads(body.decode())
            except Exception:
                obj = {"error": str(exc)}
            raise RuntimeError(obj.get("error") or str(exc)) from exc
        return json.loads(body.decode())

    def _ensure_backend(self, engine: str, idle_seconds: int) -> int:
        if self.engine == engine and self.process and self.process.poll() is None and self.port:
            return self.port
        self.stop()
        self.runtime_dir.mkdir(parents=True, exist_ok=True)
        port_file = self.runtime_dir / f"{engine}.port"
        log_file = self.runtime_dir / f"{engine}.log"
        try:
            port_file.unlink()
        except FileNotFoundError:
            pass
        python = self.asr_root / f"venv-{engine}" / "bin" / "python"
        if not python.exists():
            raise RuntimeError(f"ASR venv not found: {python}")
        if not self.script.exists():
            raise RuntimeError(f"ASR backend script not found: {self.script}")

        with log_file.open("a", encoding="utf-8") as log_handle:
            self.process = subprocess.Popen(
                [str(python), str(self.script)],
                cwd=str(self.asr_root),
                env=self._backend_env(engine, port_file, idle_seconds),
                stdout=log_handle,
                stderr=log_handle,
                text=True,
            )
        self.engine = engine
        self.port = None
        deadline = time.time() + 90
        while time.time() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError(f"ASR backend exited for {engine}; see {log_file}")
            if port_file.exists():
                value = port_file.read_text(encoding="utf-8").strip()
                if value.isdigit():
                    self.port = int(value)
                    self._health_wake.set()
                    return self.port
            time.sleep(0.25)
        raise RuntimeError(f"ASR backend did not start for {engine}; see {log_file}")

    def _backend_env(self, engine: str, port_file: Path, idle_seconds: int) -> dict[str, str]:
        env = os.environ.copy()
        env.update(
            {
                "ASR_ENGINE": engine,
                "ASR_PORT": "0",
                "ASR_PORT_FILE": str(port_file),
                "ASR_IDLE_SECONDS": str(idle_seconds),
                "HF_HOME": str(self.models_root / "hf"),
                "ASR_GIGAAM_ROOT": str(self.models_root / "gigaam"),
                "PYTORCH_ENABLE_MPS_FALLBACK": "1",
                "PYTHONUNBUFFERED": "1",
                "PATH": f"/opt/homebrew/bin:/usr/local/bin:{env.get('PATH', '')}",
            }
        )
        return env

    def stop(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.process = None
        self.engine = None
        self.port = None
        self._health_wake.set()


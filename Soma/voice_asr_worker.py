#!/usr/bin/env python3
"""The one thread that owns every MLX operation in an ASR backend process.

MLX streams are thread-affine, so model load, decode and unload must all happen
on a single thread. Keeping that thread separate from the HTTP handler threads
is what lets /health and an already-warm /warmup answer during a decode.

The owner module supplies an `on_idle` callback, invoked on this thread whenever
the queue has been quiet for a tick, so idle unloads stay thread-affine too.
"""

from __future__ import annotations

import queue
import threading
from concurrent.futures import Future
from typing import Callable

TICK_SECONDS = 1.0

_work: queue.Queue = queue.Queue()
_lock = threading.Lock()
_thread: threading.Thread | None = None
_busy = False
_on_idle: Callable[[], None] | None = None


def configure(on_idle: Callable[[], None]) -> None:
    """Register the callback run on the model thread between jobs."""
    global _on_idle
    _on_idle = on_idle


def busy() -> bool:
    return _busy


def depth() -> int:
    return _work.qsize()


def submit(job: Callable[[], object]) -> Future:
    """Queue `job` for the model thread, starting that thread on first use."""
    global _thread
    with _lock:
        if _thread is None or not _thread.is_alive():
            _thread = threading.Thread(target=_loop, name="asr-model", daemon=True)
            _thread.start()
    future: Future = Future()
    _work.put((job, future))
    return future


def run(job: Callable[[], object]):
    """Run `job` on the model thread and return its result to this caller."""
    return submit(job).result()


def _loop() -> None:
    global _busy
    while True:
        try:
            job, future = _work.get(timeout=TICK_SECONDS)
        except queue.Empty:
            if _on_idle is not None:
                _on_idle()
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

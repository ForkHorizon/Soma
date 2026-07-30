"""Concurrency contract for the voice server: no request thread ever blocks on
model work. See test_soma_voice_server.py for the protocol-level suite."""
import contextlib
import io
import json
import tempfile
import threading
import time
import types
import unittest
from unittest import mock
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

from soma_test_bootstrap import install_soma_imports

install_soma_imports()

import voice_server
import voice_asr_backend
import voice_backend_broker


class VoiceServerConcurrencyTests(unittest.TestCase):
    def request(self, method, url, body=None, token="secret", headers=None):
        all_headers = dict(headers or {})
        if token is not None:
            all_headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(url, data=body, headers=all_headers, method=method)
        with urllib.request.urlopen(req, timeout=5) as response:
            return response.status, json.loads(response.read().decode())


    def start_backend_handler(self, **patched_globals):
        """Serve voice_asr_backend.Handler with temporarily patched module globals."""
        originals = {name: getattr(voice_asr_backend, name) for name in patched_globals}
        for name, value in patched_globals.items():
            setattr(voice_asr_backend, name, value)

        def restore():
            for name, value in originals.items():
                setattr(voice_asr_backend, name, value)

        self.addCleanup(restore)
        server = ThreadingHTTPServer(("127.0.0.1", 0), voice_asr_backend.Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close()))
        return f"http://127.0.0.1:{server.server_address[1]}"

    def decoding_backend(self, **extra_globals):
        """A backend whose transcription blocks until the returned event is set."""
        decoding = threading.Event()
        release = threading.Event()
        self.addCleanup(release.set)

        def slow_transcribe(_audio, _initial_prompt=None, _language=None):
            decoding.set()
            release.wait(10)
            return "decoded"

        base = self.start_backend_handler(_loaded=True, _transcribe=slow_transcribe, **extra_globals)
        audio = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        audio.write(b"RIFFfake")
        audio.close()
        self.addCleanup(lambda: Path(audio.name).unlink(missing_ok=True))
        replies = []
        worker = threading.Thread(
            target=lambda: replies.append(self.request(
                "POST", f"{base}/transcribe",
                body=json.dumps({"audio": audio.name}).encode(),
                token=None, headers={"Content-Type": "application/json"},
            )),
            daemon=True,
        )
        worker.start()
        self.assertTrue(decoding.wait(5), "transcription never reached the model thread")
        return base, release, worker, replies

    def test_backend_health_answers_while_a_transcription_is_decoding(self):
        base, release, worker, replies = self.decoding_backend()
        started = time.monotonic()
        status, health = self.request("GET", f"{base}/health", token=None)
        elapsed = time.monotonic() - started
        self.assertEqual(status, 200)
        self.assertLess(elapsed, 1.0, "health blocked behind the in-flight decode")
        self.assertTrue(health["busy"])
        self.assertTrue(health["loaded"])

        release.set()
        worker.join(5)
        self.assertEqual(replies[0][1]["text"], "decoded")

    def test_backend_warmup_is_instant_while_a_transcription_is_decoding(self):
        loads = []
        base, release, worker, _replies = self.decoding_backend(_load=lambda: loads.append(True))
        # The in-flight transcribe job calls _load() itself; only new calls matter here.
        loads_before_warmup = len(loads)
        started = time.monotonic()
        status, payload = self.request(
            "POST", f"{base}/warmup", body=b"{}", token=None,
            headers={"Content-Type": "application/json"},
        )
        elapsed = time.monotonic() - started
        self.assertEqual(status, 200)
        self.assertLess(elapsed, 1.0, "warmup blocked behind the in-flight decode")
        self.assertTrue(payload["already_loaded"])
        self.assertEqual(len(loads), loads_before_warmup, "a warm model must not be reloaded")
        release.set()
        worker.join(5)

    def test_model_work_stays_on_one_thread(self):
        seen = []
        futures = [voice_asr_backend._submit(lambda: seen.append(threading.current_thread().name)) for _ in range(6)]
        for future in futures:
            future.result(timeout=5)
        self.assertEqual(len(seen), 6)
        self.assertEqual(set(seen), {"asr-model"}, "MLX work must stay thread-affine")

    def test_model_thread_propagates_failures_to_the_caller(self):
        def explode():
            raise RuntimeError("decode blew up")

        with self.assertRaises(RuntimeError) as raised:
            voice_asr_backend._on_model_thread(explode)
        self.assertEqual(str(raised.exception), "decode blew up")
        self.assertEqual(voice_asr_backend._on_model_thread(lambda: "still alive"), "still alive")

    def stub_broker(self, port):
        broker = voice_server.BackendBroker(Path("."), Path("."), idle_seconds=600)
        broker.engine = "whisper"
        broker.port = port
        broker.process = types.SimpleNamespace(poll=lambda: None, terminate=lambda: None, wait=lambda timeout=None: 0)
        # Stop the health refresher from polling a bogus port for the rest of the run.
        self.addCleanup(lambda: setattr(broker, "process", None))
        return broker

    def test_broker_health_never_blocks_the_calling_thread(self):
        broker = self.stub_broker(4321)

        def slow_health(_url, timeout=None):
            time.sleep(0.6)
            return contextlib.nullcontext(io.BytesIO(b'{"loaded": true, "busy": true, "idle_seconds": 600}'))

        with mock.patch("urllib.request.urlopen", side_effect=slow_health):
            started = time.monotonic()
            first = broker.health()
            self.assertLess(time.monotonic() - started, 0.2, "health did backend I/O on the request thread")
            self.assertTrue(first["backend_running"])
            self.assertFalse(first["backend_loaded"])
            self.assertIsNone(first["backend_health_age_seconds"])

            for _ in range(40):
                time.sleep(0.05)
                latest = broker.health()
                if latest["backend_loaded"]:
                    break
            self.assertTrue(latest["backend_loaded"], "background refresh never populated the snapshot")
            self.assertTrue(latest["backend_busy"])
            self.assertIsNotNone(latest["backend_health_age_seconds"])

    def test_health_refresher_stops_when_idle_and_restarts_on_demand(self):
        broker = self.stub_broker(4325)
        payload = b'{"loaded": true, "busy": false, "idle_seconds": 600}'
        with mock.patch("urllib.request.urlopen", side_effect=lambda *_a, **_k: contextlib.nullcontext(io.BytesIO(payload))), \
             mock.patch.object(voice_backend_broker, "BACKEND_HEALTH_IDLE_STOP_SECONDS", 0.0), \
             mock.patch.object(voice_backend_broker, "BACKEND_HEALTH_REFRESH_SECONDS", 0.01):
            broker.health()
            for _ in range(50):
                time.sleep(0.02)
                with broker._health_lock:
                    if broker._health_thread is None:
                        break
            else:
                self.fail("refresher kept polling with nobody asking")

            broker.health()
            with broker._health_lock:
                self.assertIsNotNone(broker._health_thread, "refresher did not restart on demand")

    def test_backend_swap_wakes_the_health_refresher(self):
        broker = self.stub_broker(4326)
        broker._health_wake.clear()
        broker.stop()
        self.assertTrue(broker._health_wake.is_set(), "a backend swap must invalidate the cached snapshot now")

    def test_broker_health_ignores_a_snapshot_from_another_backend(self):
        broker = self.stub_broker(4323)
        with broker._health_lock:
            broker._health_snapshot = {"backend_loaded": True}
            broker._health_taken_at = time.monotonic()
            broker._health_key = ("gigaam", 9999)
        health = broker.health()
        self.assertFalse(health["backend_loaded"])
        self.assertIsNone(health["backend_health_age_seconds"])

    def warm_in_background(self, broker):
        done = threading.Event()
        threading.Thread(target=lambda: (broker.warm("whisper"), done.set()), daemon=True).start()
        return done

    def test_warm_does_not_wait_for_an_in_flight_transcribe(self):
        broker = self.stub_broker(4322)
        ensured, posted = [], []
        broker._ensure_backend = lambda engine, idle: ensured.append(engine) or broker.port
        broker._post_backend = lambda port, path, payload, timeout=30: posted.append((path, timeout)) or {"ok": True}

        with broker.lock:  # exactly what BackendBroker.transcribe holds while decoding
            done = self.warm_in_background(broker)
            self.assertTrue(done.wait(2), "warmup queued behind the in-flight transcribe lock")
        self.assertEqual(ensured, [], "the warm fast path must not touch backend lifecycle")
        self.assertEqual(posted, [("/warmup", voice_server.BACKEND_WARMUP_TIMEOUT_SECONDS)])

    def test_warm_for_a_cold_backend_still_serializes_on_the_lifecycle_lock(self):
        broker = self.stub_broker(4324)
        broker.process = None  # nothing running: the fast path must not apply
        broker._ensure_backend = lambda engine, idle: 4324
        broker._post_backend = lambda port, path, payload, timeout=30: {"ok": True}

        with broker.lock:
            done = self.warm_in_background(broker)
            self.assertFalse(done.wait(0.5), "a cold start must not race backend lifecycle")
        self.assertTrue(done.wait(2), "warmup never completed after the lock was released")


if __name__ == "__main__":
    unittest.main()

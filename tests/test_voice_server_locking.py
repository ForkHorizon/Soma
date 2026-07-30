"""Locking contract: the global state lock is never held across the audio write,
and the retention sweep never runs on a request."""
import json
import threading
import time
import unittest
from unittest import mock
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

from soma_test_bootstrap import install_soma_imports

install_soma_imports()

import voice_jobs
import voice_server


class FakeBroker:
    def health(self):
        return {"backend_running": True}

    def configure(self, idle_seconds):
        pass

    def warm(self, engine, idle_seconds=None):
        return {"ok": True}

    def transcribe(self, engine, audio_path, idle_seconds=None, initial_prompt=None, language="ru"):
        return {"text": "stub", "engine": engine, "infer_seconds": 0.01}


class VoiceServerLockTests(unittest.TestCase):
    """The global state lock must never be held across the audio write, and the
    retention sweep must never run on a request."""

    def request(self, method, url, body=None, token="secret", headers=None):
        all_headers = dict(headers or {})
        if token is not None:
            all_headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(url, data=body, headers=all_headers, method=method)
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status, json.loads(response.read().decode())

    def start_server(self):
        broker = FakeBroker()
        state = voice_server.VoiceServerState(
            token="secret", broker=broker, idle_seconds=1, completed_ttl=60,
        )
        server = ThreadingHTTPServer(("127.0.0.1", 0), voice_server.make_handler(state))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close()))
        return f"http://127.0.0.1:{server.server_address[1]}", state

    def open_session(self, base, request_id="lock-session"):
        _status, session = self.request(
            "POST", f"{base}/v1/sessions",
            headers={"X-Soma-Client-ID": "client-a", "X-Soma-Request-ID": request_id},
        )
        return session["session_id"]

    def chunk_headers(self, session_id, index):
        return {
            "Content-Type": "audio/flac",
            "X-Soma-Client-ID": "client-a",
            "X-Soma-Request-ID": f"{session_id}-{index}",
        }

    def slow_spill(self, started, release):
        original = voice_jobs.spill_audio

        def spill(body, suffix):
            started.set()
            release.wait(10)
            return original(body, suffix)

        return mock.patch.object(voice_jobs, "spill_audio", spill)

    def test_chunk_upload_does_not_hold_the_lock_while_writing_audio(self):
        base, _state = self.start_server()
        session_id = self.open_session(base)
        started, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)

        with self.slow_spill(started, release):
            threading.Thread(target=lambda: self.request(
                "PUT", f"{base}/v1/sessions/{session_id}/chunks/0",
                body=b"audio", headers=self.chunk_headers(session_id, 0),
            ), daemon=True).start()
            self.assertTrue(started.wait(5), "the upload never reached the audio write")

            # The write is in progress. Anything that takes the state lock must
            # still answer; before this change /v1/status blocked behind it.
            began = time.monotonic()
            status, _payload = self.request("GET", f"{base}/v1/status")
            elapsed = time.monotonic() - began
            self.assertEqual(status, 200)
            self.assertLess(elapsed, 2.0, "the state lock was held across the audio write")
            release.set()

    def test_rejected_chunk_does_not_leave_its_audio_behind(self):
        base, _state = self.start_server()
        session_id = self.open_session(base)
        spilled = []
        original = voice_jobs.spill_audio

        def recording_spill(body, suffix):
            path = original(body, suffix)
            spilled.append(path)
            return path

        with mock.patch.object(voice_jobs, "spill_audio", recording_spill):
            # Index 3 is out of order, so the upload is refused after the spill.
            with self.assertRaises(urllib.error.HTTPError) as raised:
                self.request(
                    "PUT", f"{base}/v1/sessions/{session_id}/chunks/3",
                    body=b"audio", headers=self.chunk_headers(session_id, 3),
                )
            raised.exception.read()
            raised.exception.close()
            self.assertEqual(raised.exception.code, 409)

        self.assertEqual(len(spilled), 1, "the upload should have been spilled once")
        self.assertFalse(Path(spilled[0]).exists(), "a refused chunk must not leak its audio file")

    def test_requests_no_longer_run_the_retention_sweep(self):
        base, state = self.start_server()
        with mock.patch.object(voice_jobs, "prune") as pruned:
            session_id = self.open_session(base, request_id="sweep-session")
            self.request("GET", f"{base}/v1/sessions/{session_id}", headers={"X-Soma-Client-ID": "client-a"})
            self.request("POST", f"{base}/v1/transcriptions", body=b"audio")
            pruned.assert_not_called()
        self.assertTrue(state.pruner.is_alive(), "the sweep must still run on its own thread")

    def test_the_sweeper_still_expires_abandoned_sessions(self):
        _base, state = self.start_server()
        _status, payload = state.create_session({"x-soma-client-id": "c", "x-soma-request-id": "r"})
        session_id = payload["session_id"]
        state.abandoned_session_ttl = 1
        state.sessions[session_id].updated_at = time.time() - 2
        voice_jobs.prune(state)
        self.assertNotIn(session_id, state.sessions)


if __name__ == "__main__":
    unittest.main()

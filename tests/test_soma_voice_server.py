import contextlib
import io
import json
import plistlib
import socket
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest import mock
import urllib.error
import urllib.request
from pathlib import Path

from soma_test_bootstrap import install_soma_imports

install_soma_imports()

import voice_server
import voice_asr_backend


class FakeBroker:
    def __init__(self, delay=0.01, echo_initial_prompt=False, scripted_texts=None):
        self.calls = []
        self.configured = []
        self.warm_calls = []
        self.delay = delay
        self.echo_initial_prompt = echo_initial_prompt
        self.scripted_texts = list(scripted_texts or [])

    def health(self):
        return {
            "backend_running": True,
            "active_engine": None,
            "backend_loaded": bool(self.calls),
            "backend_idle_seconds": self.configured[-1] if self.configured else None,
        }

    def configure(self, idle_seconds):
        self.configured.append(idle_seconds)

    def warm(self, engine, idle_seconds=None):
        self.warm_calls.append((engine, idle_seconds))
        return {"ok": True, "engine": engine, "loaded": True, "already_loaded": False, "load_seconds": 0.01}

    def transcribe(self, engine, audio_path, idle_seconds=None, initial_prompt=None, language="ru"):
        audio = Path(audio_path).read_bytes()
        self.calls.append((engine, audio, idle_seconds, initial_prompt, language))
        time.sleep(self.delay)
        text = self.scripted_texts.pop(0) if self.scripted_texts else audio.decode("utf-8")
        if self.echo_initial_prompt and initial_prompt:
            text = f"{initial_prompt} {text}"
        return {"text": text, "engine": engine, "infer_seconds": 0.01}


class SomaVoiceServerTests(unittest.TestCase):
    def start_server(
        self,
        token="secret",
        allow_unauthenticated_local=False,
        max_audio_bytes=50 * 1024 * 1024,
        upload_timeout_seconds=15.0,
        settings_path=None,
        broker_delay=0.01,
        broker_echo_initial_prompt=False,
        broker_scripted_texts=None,
        max_queue=0,
        max_background_queue=0,
    ):
        broker = FakeBroker(
            delay=broker_delay,
            echo_initial_prompt=broker_echo_initial_prompt,
            scripted_texts=broker_scripted_texts,
        )
        state = voice_server.VoiceServerState(
            token=token,
            broker=broker,
            idle_seconds=1,
            completed_ttl=60,
            allow_unauthenticated_local=allow_unauthenticated_local,
            max_audio_bytes=max_audio_bytes,
            upload_timeout_seconds=upload_timeout_seconds,
            settings_path=settings_path,
            max_queue=max_queue,
            max_background_queue=max_background_queue,
        )
        server = voice_server.ThreadingHTTPServer(("127.0.0.1", 0), voice_server.make_handler(state))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close()))
        return f"http://127.0.0.1:{server.server_address[1]}", broker

    def request(self, method, url, body=None, token="secret", headers=None):
        all_headers = dict(headers or {})
        if token is not None:
            all_headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(url, data=body, headers=all_headers, method=method)
        with urllib.request.urlopen(req, timeout=5) as response:
            return response.status, json.loads(response.read().decode())

    def wait_done(self, base, job_id):
        for _ in range(50):
            _status, payload = self.request("GET", f"{base}/v1/transcriptions/{job_id}")
            if payload["status"] == "done":
                return payload
            time.sleep(0.02)
        self.fail("job did not finish")

    def wait_terminal_job(self, base, job_id):
        for _ in range(50):
            _status, payload = self.request("GET", f"{base}/v1/transcriptions/{job_id}")
            if payload["status"] in {"done", "failed"}:
                return payload
            time.sleep(0.02)
        self.fail("job did not finish")

    def test_rejects_missing_token(self):
        base, _broker = self.start_server()
        with self.assertRaises(urllib.error.HTTPError) as raised:
            self.request("GET", f"{base}/v1/health", token=None)
        raised.exception.read()
        raised.exception.close()
        self.assertEqual(raised.exception.code, 401)

    def test_rejects_empty_token_unless_local_auth_is_explicitly_allowed(self):
        base, _broker = self.start_server(token="")
        with self.assertRaises(urllib.error.HTTPError) as raised:
            self.request("GET", f"{base}/v1/health", token=None)
        raised.exception.read()
        raised.exception.close()
        self.assertEqual(raised.exception.code, 401)

        base, _broker = self.start_server(token="", allow_unauthenticated_local=True)
        status, payload = self.request("GET", f"{base}/v1/health", token=None)
        self.assertEqual(status, 200)
        self.assertTrue(payload["ok"])

    def test_prunes_abandoned_unfinalized_session(self):
        state = voice_server.VoiceServerState(
            token="secret",
            broker=FakeBroker(),
            completed_ttl=60,
            abandoned_session_ttl=1,
        )
        _status, payload = state.create_session({"x-soma-client-id": "client", "x-soma-request-id": "request"})
        session_id = payload["session_id"]
        state.sessions[session_id].updated_at = time.time() - 2
        state._prune()
        self.assertNotIn(session_id, state.sessions)

    def test_main_requires_token_unless_local_auth_is_explicitly_allowed(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                voice_server.main(["--host", "127.0.0.1", "--port", "0"])
        self.assertEqual(raised.exception.code, 2)
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                voice_server.main(["--token", "   ", "--host", "127.0.0.1", "--port", "0"])
        self.assertEqual(raised.exception.code, 2)

    def test_submit_and_poll_transcription(self):
        base, broker = self.start_server()
        status, payload = self.request(
            "POST",
            f"{base}/v1/transcriptions",
            body=b"RIFFfake",
            headers={
                "X-Soma-Client-ID": "client-a",
                "X-Soma-Request-ID": "req-1",
                "X-Soma-Engine": "gigaam",
            },
        )
        self.assertEqual(status, 202)
        done = self.wait_done(base, payload["job_id"])
        self.assertEqual(done["text"], "RIFFfake")
        self.assertEqual(broker.calls[0][0], "gigaam")

    def test_health_advertises_v2_chunk_capabilities(self):
        base, _broker = self.start_server()
        status, payload = self.request("GET", f"{base}/v1/health")
        self.assertEqual(status, 200)
        self.assertEqual(payload["version"], 2)
        self.assertTrue({"warmup", "chunk_sessions", "long_poll", "flac", "priority_queue", "final_chunk_finalize"}.issubset(payload["capabilities"]))

    def test_flac_final_chunk_finalizes_a_session_without_an_extra_request(self):
        base, broker = self.start_server()
        _status, session = self.request(
            "POST", f"{base}/v1/sessions",
            headers={"X-Soma-Client-ID": "client-a", "X-Soma-Request-ID": "session-flac"},
        )
        session_id = session["session_id"]
        status, _payload = self.request(
            "PUT", f"{base}/v1/sessions/{session_id}/chunks/0",
            body=b"lossless-audio",
            headers={
                "Content-Type": "audio/flac",
                "X-Soma-Client-ID": "client-a",
                "X-Soma-Request-ID": f"{session_id}-0",
                "X-Soma-Chunk-Reason": "final",
                "X-Soma-Finalize-Session": "1",
            },
        )
        self.assertEqual(status, 202)
        status, done = self.request("GET", f"{base}/v1/sessions/{session_id}?wait=2", headers={"X-Soma-Client-ID": "client-a"})
        self.assertEqual(status, 200)
        self.assertEqual(done["status"], "done")
        self.assertEqual(done["text"], "lossless-audio")
        self.assertEqual(broker.calls[0][1], b"lossless-audio")

    def test_media_session_retries_bad_chunk_then_strips_previous_audio_context(self):
        base, broker = self.start_server(broker_scripted_texts=[
            "previous context",
            "again " * 12,
            "again " * 12,
            "previous context repaired current transcript",
        ])
        _status, session = self.request(
            "POST", f"{base}/v1/sessions",
            headers={
                "X-Soma-Client-ID": "client-a",
                "X-Soma-Request-ID": "session-auto",
                "X-Soma-Language": "auto",
            },
        )
        session_id = session["session_id"]
        status, _payload = self.request(
            "PUT", f"{base}/v1/sessions/{session_id}/chunks/0",
            body=b"previous-audio",
            headers={
                "Content-Type": "audio/flac",
                "X-Soma-Client-ID": "client-a",
                "X-Soma-Request-ID": f"{session_id}-0-0",
                "X-Soma-Work-Class": "background",
                "X-Soma-Chunk-Reason": "forced",
            },
        )
        self.assertEqual(status, 202)
        first = self.wait_terminal_job(base, _payload["job_id"])
        self.assertEqual(first["status"], "done")

        headers = {
            "Content-Type": "audio/flac",
            "X-Soma-Client-ID": "client-a",
            "X-Soma-Work-Class": "background",
            "X-Soma-Chunk-Recovery": "client-v1",
            "X-Soma-Chunk-Reason": "final",
            "X-Soma-Finalize-Session": "1",
        }
        _status, first_attempt = self.request(
            "PUT", f"{base}/v1/sessions/{session_id}/chunks/1", body=b"current-audio",
            headers={**headers, "X-Soma-Request-ID": f"{session_id}-1-0"},
        )
        self.assertEqual(self.wait_terminal_job(base, first_attempt["job_id"])["error"]["code"], "pathological_repetition")
        _status, second_attempt = self.request(
            "PUT", f"{base}/v1/sessions/{session_id}/chunks/1", body=b"current-audio",
            headers={**headers, "X-Soma-Request-ID": f"{session_id}-1-1", "X-Soma-Retry-Failed-Chunk": "1"},
        )
        self.assertEqual(self.wait_terminal_job(base, second_attempt["job_id"])["error"]["code"], "pathological_repetition")
        _status, third_attempt = self.request(
            "PUT", f"{base}/v1/sessions/{session_id}/chunks/1", body=b"previous-plus-current",
            headers={**headers, "X-Soma-Request-ID": f"{session_id}-1-2", "X-Soma-Retry-Failed-Chunk": "1", "X-Soma-Context-Chunk-Index": "0"},
        )
        self.assertEqual(self.wait_terminal_job(base, third_attempt["job_id"])["status"], "done")
        _status, done = self.request("GET", f"{base}/v1/sessions/{session_id}?wait=2", headers={"X-Soma-Client-ID": "client-a"})
        self.assertEqual(done["status"], "done")
        self.assertEqual(done["text"], "previous context repaired current transcript")
        self.assertEqual([call[4] for call in broker.calls], ["auto"] * 4)

    def test_live_work_runs_before_waiting_background_work(self):
        base, broker = self.start_server(broker_delay=0.15)
        common = {"X-Soma-Client-ID": "client-a", "Content-Type": "audio/flac"}
        _status, first = self.request(
            "POST", f"{base}/v1/transcriptions", body=b"background-1",
            headers={**common, "X-Soma-Request-ID": "background-1", "X-Soma-Work-Class": "background"},
        )
        _status, second = self.request(
            "POST", f"{base}/v1/transcriptions", body=b"background-2",
            headers={**common, "X-Soma-Request-ID": "background-2", "X-Soma-Work-Class": "background"},
        )
        _status, live = self.request(
            "POST", f"{base}/v1/transcriptions", body=b"live",
            headers={**common, "X-Soma-Request-ID": "live", "X-Soma-Work-Class": "interactive"},
        )
        self.wait_done(base, first["job_id"])
        self.wait_done(base, second["job_id"])
        self.wait_done(base, live["job_id"])
        order = [call[1] for call in broker.calls]
        self.assertLess(order.index(b"live"), order.index(b"background-2"))

    def test_media_backlog_is_unlimited_by_default(self):
        base, _broker = self.start_server(broker_delay=0.2)
        headers = {
            "X-Soma-Client-ID": "client-a",
            "Content-Type": "audio/flac",
            "X-Soma-Work-Class": "background",
        }
        for index in range(40):
            status, _payload = self.request(
                "POST", f"{base}/v1/transcriptions", body=f"media-{index}".encode(),
                headers={**headers, "X-Soma-Request-ID": f"media-{index}"},
            )
            self.assertEqual(status, 202)

    def test_warmup_is_authenticated_and_idempotent(self):
        base, broker = self.start_server()
        headers = {"X-Soma-Engine": "whisper", "X-Soma-Idle-Seconds": "42"}
        status, payload = self.request("POST", f"{base}/v1/warmup", headers=headers)
        self.assertEqual(status, 200)
        self.assertTrue(payload["loaded"])
        self.assertEqual(broker.warm_calls, [("whisper", 42)])

    def test_forced_overlap_chunks_receive_whisper_context(self):
        base, broker = self.start_server()
        session_headers = {"X-Soma-Client-ID": "client-a", "X-Soma-Request-ID": "session-a", "X-Soma-Engine": "whisper"}
        status, session = self.request("POST", f"{base}/v1/sessions", headers=session_headers)
        self.assertEqual(status, 201)
        session_id = session["session_id"]

        for index, body in enumerate((b"first", b"second")):
            headers = {
                "Content-Type": "audio/wav",
                "X-Soma-Client-ID": "client-a",
                "X-Soma-Request-ID": f"{session_id}-{index}",
                "X-Soma-Chunk-Reason": "forced" if index == 1 else "pause",
                "X-Soma-Overlap-Milliseconds": "750" if index == 1 else "0",
                "X-Soma-Chunk-Duration-Milliseconds": "3000",
            }
            status, payload = self.request("PUT", f"{base}/v1/sessions/{session_id}/chunks/{index}", body=body, headers=headers)
            self.assertEqual(status, 202)
            self.assertEqual(payload["status"], "queued")

        status, _payload = self.request("POST", f"{base}/v1/sessions/{session_id}/finalize", headers={"X-Soma-Client-ID": "client-a"})
        self.assertEqual(status, 200)
        status, done = self.request("GET", f"{base}/v1/sessions/{session_id}?wait=2", headers={"X-Soma-Client-ID": "client-a"})
        self.assertEqual(status, 200)
        self.assertEqual(done["status"], "done")
        self.assertEqual(done["text"], "first second")
        self.assertEqual(broker.calls[0][1], b"first")
        self.assertEqual(broker.calls[1][1], b"second")
        self.assertEqual(broker.calls[1][3], "first")

    def test_pause_chunks_do_not_echo_prior_whisper_transcript(self):
        base, broker = self.start_server(broker_echo_initial_prompt=True)
        session_headers = {"X-Soma-Client-ID": "client-a", "X-Soma-Request-ID": "session-pause", "X-Soma-Engine": "whisper"}
        status, session = self.request("POST", f"{base}/v1/sessions", headers=session_headers)
        self.assertEqual(status, 201)
        session_id = session["session_id"]

        for index, body in enumerate((b"first", b"second")):
            headers = {
                "Content-Type": "audio/wav",
                "X-Soma-Client-ID": "client-a",
                "X-Soma-Request-ID": f"{session_id}-{index}",
                "X-Soma-Chunk-Reason": "pause",
                "X-Soma-Chunk-Duration-Milliseconds": "3000",
            }
            status, _payload = self.request("PUT", f"{base}/v1/sessions/{session_id}/chunks/{index}", body=body, headers=headers)
            self.assertEqual(status, 202)

        status, _payload = self.request("POST", f"{base}/v1/sessions/{session_id}/finalize", headers={"X-Soma-Client-ID": "client-a"})
        self.assertEqual(status, 200)
        status, done = self.request("GET", f"{base}/v1/sessions/{session_id}?wait=2", headers={"X-Soma-Client-ID": "client-a"})
        self.assertEqual(status, 200)
        self.assertEqual(done["text"], "first second")
        self.assertIsNone(broker.calls[1][3])

    def test_chunk_session_rejects_future_chunk_and_accepts_idempotent_retry(self):
        base, _broker = self.start_server()
        status, session = self.request(
            "POST", f"{base}/v1/sessions",
            headers={"X-Soma-Client-ID": "client-a", "X-Soma-Request-ID": "session-order"},
        )
        self.assertEqual(status, 201)
        session_id = session["session_id"]
        headers = {"X-Soma-Client-ID": "client-a", "X-Soma-Request-ID": f"{session_id}-1"}
        with self.assertRaises(urllib.error.HTTPError) as raised:
            self.request("PUT", f"{base}/v1/sessions/{session_id}/chunks/1", body=b"late", headers=headers)
        payload = json.loads(raised.exception.read().decode())
        raised.exception.close()
        self.assertEqual(raised.exception.code, 409)
        self.assertEqual(payload["expected_chunk_index"], 0)

        headers["X-Soma-Request-ID"] = f"{session_id}-0"
        _status, first = self.request("PUT", f"{base}/v1/sessions/{session_id}/chunks/0", body=b"first", headers=headers)
        _status, retry = self.request("PUT", f"{base}/v1/sessions/{session_id}/chunks/0", body=b"first", headers=headers)
        self.assertEqual(first["job_id"], retry["job_id"])
        headers["X-Soma-Request-ID"] = f"{session_id}-0-after-relaunch"
        _status, resumed = self.request("PUT", f"{base}/v1/sessions/{session_id}/chunks/0", body=b"first", headers=headers)
        self.assertEqual(first["job_id"], resumed["job_id"])

    def test_forced_overlap_reports_unsafe_when_words_do_not_match(self):
        self.assertEqual(voice_server.VoiceServerState._join_overlap("hello world", "world again"), ("hello world again", True))
        self.assertEqual(voice_server.VoiceServerState._join_overlap("hello world", "different words"), ("hello world different words", False))

    def test_repetition_guard_rejects_decoder_loops(self):
        self.assertFalse(voice_server.VoiceServerState._has_pathological_repetition("yes yes yes yes"))
        self.assertTrue(voice_server.VoiceServerState._has_pathological_repetition("already " * 12))
        self.assertTrue(voice_server.VoiceServerState._has_pathological_repetition("come back here for a second " * 3))
        self.assertTrue(voice_server.VoiceServerState._has_pathological_repetition("f sağ " * 6))
        self.assertTrue(voice_server.VoiceServerState._has_pathological_repetition("... " * 8))

    def test_backend_auto_language_omits_the_forced_language(self):
        self.assertIsNone(voice_asr_backend._requested_language({"language": "auto"}))
        self.assertEqual(voice_asr_backend._requested_language({"language": "ru"}), "ru")
        with self.assertRaises(ValueError):
            voice_asr_backend._requested_language({"language": None})

    def test_cancel_session_discards_queued_chunk_result(self):
        base, broker = self.start_server(broker_delay=0.2)
        status, session = self.request(
            "POST", f"{base}/v1/sessions",
            headers={"X-Soma-Client-ID": "client-a", "X-Soma-Request-ID": "session-cancel"},
        )
        self.assertEqual(status, 201)
        session_id = session["session_id"]
        status, _payload = self.request(
            "PUT", f"{base}/v1/sessions/{session_id}/chunks/0",
            body=b"audio",
            headers={"X-Soma-Client-ID": "client-a", "X-Soma-Request-ID": f"{session_id}-0"},
        )
        self.assertEqual(status, 202)
        status, canceled = self.request("DELETE", f"{base}/v1/sessions/{session_id}", headers={"X-Soma-Client-ID": "client-a"})
        self.assertEqual(status, 200)
        self.assertEqual(canceled["status"], "canceled")
        time.sleep(0.25)
        status, state = self.request("GET", f"{base}/v1/sessions/{session_id}", headers={"X-Soma-Client-ID": "client-a"})
        self.assertEqual(status, 200)
        self.assertEqual(state["status"], "canceled")
        self.assertLessEqual(len(broker.calls), 1)

    def test_status_reports_queue_backend_and_settings(self):
        base, broker = self.start_server(broker_delay=0.2)
        first_status, first = self.request("POST", f"{base}/v1/transcriptions", body=b"one")
        second_status, _second = self.request("POST", f"{base}/v1/transcriptions", body=b"two")
        self.assertEqual(first_status, 202)
        self.assertEqual(second_status, 202)
        for _ in range(30):
            _status, payload = self.request("GET", f"{base}/v1/status")
            if payload["queue"]["running"] == 1 and payload["queue"]["queued"] == 1:
                break
            time.sleep(0.01)
        else:
            self.fail("status did not expose active and queued work")
        self.assertEqual(payload["settings"]["idle_seconds"], 1)
        self.assertEqual(payload["queue"]["active_job"]["job_id"], first["job_id"])
        self.assertTrue(payload["backend"]["backend_running"])
        self.assertEqual(broker.configured[-1], 1)

    def test_patch_settings_updates_broker_and_persists(self):
        with tempfile.TemporaryDirectory() as tmp:
            settings_path = Path(tmp) / "settings.json"
            base, broker = self.start_server(settings_path=settings_path)
            status, payload = self.request(
                "PATCH",
                f"{base}/v1/settings",
                body=b'{"idle_seconds": 42}',
                headers={"Content-Type": "application/json"},
            )
            self.assertEqual(status, 200)
            self.assertEqual(payload["settings"]["idle_seconds"], 42)
            self.assertEqual(broker.configured[-1], 42)
            self.assertEqual(json.loads(settings_path.read_text())["idle_seconds"], 42)

    def test_state_loads_persisted_idle_settings(self):
        with tempfile.TemporaryDirectory() as tmp:
            settings_path = Path(tmp) / "settings.json"
            settings_path.write_text('{"idle_seconds": 33}', encoding="utf-8")
            _base, broker = self.start_server(settings_path=settings_path)
            self.assertEqual(broker.configured[-1], 33)

    def test_rejects_oversized_upload_from_content_length(self):
        base, broker = self.start_server(max_audio_bytes=4)
        with self.assertRaises(urllib.error.HTTPError) as raised:
            self.request("POST", f"{base}/v1/transcriptions", body=b"12345")
        raised.exception.read()
        raised.exception.close()
        self.assertEqual(raised.exception.code, 413)
        self.assertEqual(broker.calls, [])

    def test_rejects_incomplete_upload_without_queueing_job(self):
        base, broker = self.start_server()
        host, port = base.removeprefix("http://").split(":")
        with socket.create_connection((host, int(port)), timeout=5) as sock:
            sock.sendall(
                b"POST /v1/transcriptions HTTP/1.1\r\n"
                b"Host: 127.0.0.1\r\n"
                b"Authorization: Bearer secret\r\n"
                b"Content-Length: 8\r\n"
                b"\r\n"
                b"RIFF"
            )
            sock.shutdown(socket.SHUT_WR)
            chunks = []
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
            response = b"".join(chunks)
        self.assertIn(b" 400 ", response.splitlines()[0])
        self.assertIn(b"incomplete_upload", response)
        self.assertEqual(broker.calls, [])

    def test_times_out_stalled_upload_without_queueing_job(self):
        base, broker = self.start_server(upload_timeout_seconds=0.1)
        host, port = base.removeprefix("http://").split(":")
        with socket.create_connection((host, int(port)), timeout=5) as sock:
            sock.sendall(
                b"POST /v1/transcriptions HTTP/1.1\r\n"
                b"Host: 127.0.0.1\r\n"
                b"Authorization: Bearer secret\r\n"
                b"Content-Length: 8\r\n"
                b"\r\n"
                b"RIFF"
            )
            chunks = []
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
            response = b"".join(chunks)
        self.assertIn(b" 408 ", response.splitlines()[0])
        self.assertIn(b"upload_timeout", response)
        self.assertEqual(broker.calls, [])

    def test_backend_preserves_zero_idle(self):
        broker = voice_server.BackendBroker(Path("."), Path("."), idle_seconds=600)
        seen = []
        broker._ensure_backend = lambda _engine, idle_seconds: seen.append(idle_seconds) or 12345
        response = contextlib.nullcontext(io.BytesIO(b'{"text": "ok"}'))
        with mock.patch("urllib.request.urlopen", return_value=response) as opened:
            broker.transcribe("whisper", "/tmp/fake.wav", idle_seconds=0)
        payload = json.loads(opened.call_args.args[0].data.decode())
        self.assertEqual(seen, [0])
        self.assertEqual(payload["idle_seconds"], 0)

    def test_launch_agent_keeps_models_root_and_queue_config(self):
        args = voice_server.parse_args([
            "--token", "secret",
            "--asr-root", "/tmp/asr",
            "--models-root", "/tmp/models",
            "--max-queue", "7",
            "--allow-unauthenticated-local",
        ])
        with tempfile.TemporaryDirectory() as home:
            with mock.patch.object(voice_server.Path, "home", return_value=Path(home)):
                plist = voice_server.install_launch_agent(args)
                data = plistlib.loads(plist.read_bytes())
        program_args = data["ProgramArguments"]
        self.assertIn("--models-root", program_args)
        self.assertIn("/tmp/models", program_args)
        self.assertIn("--max-queue", program_args)
        self.assertIn("7", program_args)
        self.assertIn("--allow-unauthenticated-local", program_args)
        self.assertEqual(data["EnvironmentVariables"]["SOMA_VOICE_TOKEN"], "secret")

    def test_request_id_is_idempotent(self):
        base, broker = self.start_server()
        headers = {"X-Soma-Client-ID": "client-a", "X-Soma-Request-ID": "same"}
        _status, first = self.request("POST", f"{base}/v1/transcriptions", body=b"one", headers=headers)
        _status, second = self.request("POST", f"{base}/v1/transcriptions", body=b"two", headers=headers)
        self.assertEqual(first["job_id"], second["job_id"])
        done = self.wait_done(base, first["job_id"])
        self.assertEqual(done["text"], "one")
        self.assertEqual(len(broker.calls), 1)
        self.assertEqual(broker.calls[0][1], b"one")

    def test_missing_job_returns_normal_error_shape(self):
        base, _broker = self.start_server()
        with self.assertRaises(urllib.error.HTTPError) as raised:
            self.request("GET", f"{base}/v1/transcriptions/missing")
        body = json.loads(raised.exception.read().decode())
        raised.exception.close()
        self.assertEqual(raised.exception.code, 404)
        self.assertEqual(body["error"]["code"], "job_not_found")

    def test_gigaam_join_removes_exact_overlap(self):
        self.assertEqual(
            voice_asr_backend._join_parts(["hello brave world", "brave world again", "again today"]),
            "hello brave world again today",
        )

    def test_backend_health_and_configure_report_idle_state(self):
        original_idle = voice_asr_backend._idle_seconds
        original_loaded = voice_asr_backend._loaded
        try:
            voice_asr_backend._idle_seconds = 10
            voice_asr_backend._loaded = False
            server = voice_server.ThreadingHTTPServer(("127.0.0.1", 0), voice_asr_backend.Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.addCleanup(lambda: (server.shutdown(), server.server_close()))
            base = f"http://127.0.0.1:{server.server_address[1]}"

            status, health = self.request("GET", f"{base}/health", token=None)
            self.assertEqual(status, 200)
            self.assertEqual(health["idle_seconds"], 10)
            self.assertFalse(health["loaded"])

            status, configured = self.request(
                "POST",
                f"{base}/configure",
                body=b'{"idle_seconds": 5}',
                token=None,
                headers={"Content-Type": "application/json"},
            )
            self.assertEqual(status, 200)
            self.assertEqual(configured["idle_seconds"], 5)
        finally:
            voice_asr_backend._idle_seconds = original_idle
            voice_asr_backend._loaded = original_loaded

    def test_backend_warmup_reports_load_without_real_model(self):
        original_load = voice_asr_backend._load
        original_loaded = voice_asr_backend._loaded
        try:
            calls = []
            def fake_load():
                calls.append(True)
                voice_asr_backend._loaded = True
            voice_asr_backend._loaded = False
            voice_asr_backend._load = fake_load
            server = voice_server.ThreadingHTTPServer(("127.0.0.1", 0), voice_asr_backend.Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.addCleanup(lambda: (server.shutdown(), server.server_close()))
            base = f"http://127.0.0.1:{server.server_address[1]}"
            status, payload = self.request("POST", f"{base}/warmup", body=b"{}", token=None, headers={"Content-Type": "application/json"})
            self.assertEqual(status, 200)
            self.assertTrue(payload["loaded"])
            self.assertFalse(payload["already_loaded"])
            self.assertEqual(calls, [True])
        finally:
            voice_asr_backend._load = original_load
            voice_asr_backend._loaded = original_loaded

    # --- Task 1: no request thread ever blocks on model work ------------------

    def start_backend_handler(self, **patched_globals):
        """Serve voice_asr_backend.Handler with temporarily patched module globals."""
        originals = {name: getattr(voice_asr_backend, name) for name in patched_globals}
        for name, value in patched_globals.items():
            setattr(voice_asr_backend, name, value)

        def restore():
            for name, value in originals.items():
                setattr(voice_asr_backend, name, value)

        self.addCleanup(restore)
        server = voice_server.ThreadingHTTPServer(("127.0.0.1", 0), voice_asr_backend.Handler)
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
        broker.process = types.SimpleNamespace(poll=lambda: None)
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

    def test_whisper_load_and_unload_own_the_actual_model_holder(self):
        original_engine = voice_asr_backend.ENGINE
        original_model = voice_asr_backend._model
        original_loaded = voice_asr_backend._loaded
        cleared = []

        class FakeModelHolder:
            model = None
            model_path = None
            calls = []

            @classmethod
            def get_model(cls, repository, dtype):
                cls.calls.append((repository, dtype))
                cls.model = object()
                cls.model_path = repository
                return cls.model

        fake_core = types.ModuleType("mlx.core")
        fake_core.float16 = "fp16"
        fake_core.clear_cache = lambda: cleared.append(True)
        fake_mlx = types.ModuleType("mlx")
        fake_mlx.core = fake_core
        fake_transcribe = types.ModuleType("mlx_whisper.transcribe")
        fake_transcribe.ModelHolder = FakeModelHolder
        fake_whisper = types.ModuleType("mlx_whisper")
        fake_whisper.transcribe = fake_transcribe

        try:
            voice_asr_backend.ENGINE = "whisper"
            voice_asr_backend._model = None
            voice_asr_backend._loaded = False
            with mock.patch.dict(sys.modules, {
                "mlx": fake_mlx,
                "mlx.core": fake_core,
                "mlx_whisper": fake_whisper,
                "mlx_whisper.transcribe": fake_transcribe,
            }):
                voice_asr_backend._load()
                self.assertEqual(FakeModelHolder.calls, [(voice_asr_backend.WHISPER_REPO, "fp16")])
                self.assertTrue(voice_asr_backend._loaded)
                self.assertIsNotNone(FakeModelHolder.model)

                voice_asr_backend._unload()
                self.assertFalse(voice_asr_backend._loaded)
                self.assertIsNone(FakeModelHolder.model)
                self.assertIsNone(FakeModelHolder.model_path)
                self.assertEqual(cleared, [True])
        finally:
            voice_asr_backend.ENGINE = original_engine
            voice_asr_backend._model = original_model
            voice_asr_backend._loaded = original_loaded

if __name__ == "__main__":
    unittest.main()

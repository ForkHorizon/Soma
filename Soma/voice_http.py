#!/usr/bin/env python3
"""HTTP surface for Soma Voice Server: auth, body reading, and routing.

Every handler here is thin — it parses the request and hands off to
VoiceServerState. No handler may block on model work; see voice_asr_worker.
"""
from __future__ import annotations

import hmac
import json
import socket
from http.server import BaseHTTPRequestHandler
from typing import TYPE_CHECKING, Any
from urllib.parse import parse_qs, urlsplit

if TYPE_CHECKING:  # `from __future__ import annotations` keeps this out of runtime
    from voice_server import VoiceServerState



class VoiceHTTPHandler(BaseHTTPRequestHandler):
    """Routing only. `state` is bound per-server by make_handler."""

    protocol_version = "HTTP/1.1"
    state: VoiceServerState

    def _auth_ok(self) -> bool:
        if self.state.token:
            return hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {self.state.token}")
        return self.state.allow_unauthenticated_local and self.client_address[0] in {"127.0.0.1", "::1"}

    def _content_length(self) -> int | None:
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length < 0:
                raise ValueError
            return length
        except ValueError:
            self._reply(*self.state.error(400, "bad_content_length", "Invalid Content-Length.", retryable=False))
            return None

    def _reply(self, code: int, obj: dict[str, Any]) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self, content_length: int) -> bytes | None:
        previous_timeout = self.connection.gettimeout()
        self.connection.settimeout(self.state.upload_timeout_seconds)
        try:
            body = self.rfile.read(content_length)
        except (TimeoutError, socket.timeout, OSError):
            self.close_connection = True
            self._reply(*self.state.error(408, "upload_timeout", "Timed out while receiving audio bytes.", retryable=True))
            return None
        finally:
            try:
                self.connection.settimeout(previous_timeout)
            except OSError:
                pass
        if len(body) != content_length:
            self.close_connection = True
            self._reply(*self.state.error(
                400,
                "incomplete_upload",
                "Upload ended before all audio bytes were received.",
                retryable=True,
            ))
            return None
        return body

    def _guard_auth(self) -> bool:
        if self._auth_ok():
            return True
        self._reply(*self.state.error(401, "unauthorized", "Missing or invalid Soma Voice token.", retryable=False))
        return False

    @staticmethod
    def _since_completed(query: dict[str, list[str]]) -> int | None:
        """Wake the long poll as soon as more chunks than this have decoded."""
        try:
            return max(0, int(query["since_completed"][0]))
        except (KeyError, IndexError, TypeError, ValueError):
            return None

    @staticmethod
    def _wait_seconds(query: dict[str, list[str]]) -> float:
        try:
            return max(0.0, min(25.0, float(query.get("wait", ["0"])[0])))
        except (TypeError, ValueError):
            return 0.0

    def _headers(self) -> dict[str, str]:
        return {key.lower(): value for key, value in self.headers.items()}

    def do_GET(self) -> None:
        if not self._guard_auth():
            return
        parsed = urlsplit(self.path)
        if parsed.path == "/v1/health":
            self._reply(200, self.state.health())
            return
        if parsed.path == "/v1/status":
            self._reply(200, self.state.status())
            return
        prefix = "/v1/transcriptions/"
        if parsed.path.startswith(prefix):
            self._reply(*self.state.get(parsed.path.removeprefix(prefix), self._wait_seconds(parse_qs(parsed.query))))
            return
        session_prefix = "/v1/sessions/"
        if parsed.path.startswith(session_prefix):
            query = parse_qs(parsed.query)
            self._reply(*self.state.get_session(
                parsed.path.removeprefix(session_prefix),
                self._headers(),
                self._wait_seconds(query),
                self._since_completed(query),
            ))
            return
        self._reply(*self.state.error(404, "not_found", "Endpoint not found.", retryable=False))

    def do_PATCH(self) -> None:
        if not self._guard_auth():
            return
        if self.path != "/v1/settings":
            self._reply(*self.state.error(404, "not_found", "Endpoint not found.", retryable=False))
            return
        content_length = self._content_length()
        if content_length is None:
            return
        body = self._read_body(content_length)
        if body is None:
            return
        try:
            payload = json.loads(body.decode() or "{}")
        except json.JSONDecodeError:
            self._reply(*self.state.error(400, "bad_json", "Request body must be JSON.", retryable=False))
            return
        if not isinstance(payload, dict):
            self._reply(*self.state.error(400, "bad_json", "Request body must be a JSON object.", retryable=False))
            return
        self._reply(*self.state.update_settings(payload))

    def do_POST(self) -> None:
        if not self._guard_auth():
            return
        parsed = urlsplit(self.path)
        if parsed.path == "/v1/warmup":
            self._reply(*self.state.warm(self._headers()))
            return
        if parsed.path == "/v1/sessions":
            self._reply(*self.state.create_session(self._headers()))
            return
        session_prefix = "/v1/sessions/"
        if parsed.path.startswith(session_prefix) and parsed.path.endswith("/finalize"):
            session_id = parsed.path.removeprefix(session_prefix).removesuffix("/finalize")
            self._reply(*self.state.finalize_session(session_id, self._headers()))
            return
        if parsed.path != "/v1/transcriptions":
            self._reply(*self.state.error(404, "not_found", "Endpoint not found.", retryable=False))
            return
        content_length = self._content_length()
        if content_length is None:
            return
        if content_length > self.state.max_audio_bytes:
            self.close_connection = True
            self._reply(*self.state.error(413, "audio_too_large", "Audio file is too large.", retryable=False))
            return
        body = self._read_body(content_length)
        if body is None:
            return
        self._reply(*self.state.submit(self._headers(), body))

    def do_PUT(self) -> None:
        if not self._guard_auth():
            return
        parsed = urlsplit(self.path)
        prefix = "/v1/sessions/"
        if not parsed.path.startswith(prefix):
            self._reply(*self.state.error(404, "not_found", "Endpoint not found.", retryable=False))
            return
        parts = parsed.path.removeprefix(prefix).split("/")
        if len(parts) != 3 or parts[1] != "chunks" or not parts[0]:
            self._reply(*self.state.error(404, "not_found", "Endpoint not found.", retryable=False))
            return
        try:
            index = int(parts[2])
        except ValueError:
            self._reply(*self.state.error(400, "bad_chunk_index", "Chunk index must be an integer.", retryable=False))
            return
        content_length = self._content_length()
        if content_length is None:
            return
        if content_length > self.state.max_audio_bytes:
            self.close_connection = True
            self._reply(*self.state.error(413, "audio_too_large", "Audio file is too large.", retryable=False))
            return
        body = self._read_body(content_length)
        if body is None:
            return
        self._reply(*self.state.submit_session_chunk(parts[0], index, self._headers(), body))

    def do_DELETE(self) -> None:
        if not self._guard_auth():
            return
        parsed = urlsplit(self.path)
        prefix = "/v1/sessions/"
        session_id = parsed.path.removeprefix(prefix) if parsed.path.startswith(prefix) else ""
        if not session_id or "/" in session_id:
            self._reply(*self.state.error(404, "not_found", "Endpoint not found.", retryable=False))
            return
        self._reply(*self.state.cancel_session(session_id, self._headers()))

    def log_message(self, *_args) -> None:
        pass


def make_handler(state: VoiceServerState) -> type[BaseHTTPRequestHandler]:
    return type("Handler", (VoiceHTTPHandler,), {"state": state})

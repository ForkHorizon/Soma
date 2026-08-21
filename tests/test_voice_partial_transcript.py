"""Transcript visibility while a session is still recording.

Chunks decode while the user is still speaking; a measured median of 86% of the
final text is on the server by the time they release the key. These pin down
that it is reachable, and reachable in time to be useful.
"""

import json
import threading
import time
import unittest
import urllib.request
from http.server import ThreadingHTTPServer

from soma_test_bootstrap import install_soma_imports

install_soma_imports()

import voice_server
from test_soma_voice_server import FakeBroker


class VoicePartialTranscriptTests(unittest.TestCase):
    def start_server(self):
        state = voice_server.VoiceServerState(token="secret", broker=FakeBroker(), idle_seconds=1, completed_ttl=60)
        server = ThreadingHTTPServer(("127.0.0.1", 0), voice_server.make_handler(state))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close()))
        return f"http://127.0.0.1:{server.server_address[1]}", state

    def request(self, method, url, body=None, token="secret", headers=None):
        all_headers = dict(headers or {})
        if token is not None:
            all_headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(url, data=body, headers=all_headers, method=method)
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status, json.loads(response.read().decode())

    def test_session_exposes_decoded_text_before_it_is_finalized(self):
        """Chunks decode while the user is still speaking; measured at a median
        86% of the transcript by release. Without this the client cannot see any
        of it until the merge, and nothing downstream can start early."""
        base, _state = self.start_server()
        _status, session = self.request(
            "POST",
            f"{base}/v1/sessions",
            headers={"X-Soma-Client-ID": "client-a", "X-Soma-Request-ID": "session-partial"},
        )
        session_id = session["session_id"]
        for index, body in enumerate((b"first phrase", b"second phrase")):
            status, _payload = self.request(
                "PUT",
                f"{base}/v1/sessions/{session_id}/chunks/{index}",
                body=body,
                headers={
                    "Content-Type": "audio/flac",
                    "X-Soma-Client-ID": "client-a",
                    "X-Soma-Request-ID": f"{session_id}-{index}",
                    "X-Soma-Chunk-Reason": "pause",
                },
            )
            self.assertEqual(status, 202)

        for _ in range(50):
            _status, live = self.request(
                "GET", f"{base}/v1/sessions/{session_id}", headers={"X-Soma-Client-ID": "client-a"}
            )
            if live.get("partial_text"):
                break
            time.sleep(0.02)
        self.assertEqual(live["status"], "recording", "still recording, not finalized")
        self.assertNotIn("text", live, "text is reserved for the finalized transcript")
        self.assertEqual(live["partial_text"], "first phrase second phrase")

        # A progress long-poll returns as soon as another chunk decodes, rather
        # than blocking until the session finishes — that is what makes the
        # partial usable while the user is still speaking.
        began = time.monotonic()
        _status, progressed = self.request(
            "GET", f"{base}/v1/sessions/{session_id}?wait=5&since_completed=0", headers={"X-Soma-Client-ID": "client-a"}
        )
        self.assertLess(time.monotonic() - began, 2.0, "progress poll blocked for the full wait")
        self.assertGreater(progressed["completed_chunks"], 0)

        self.request("POST", f"{base}/v1/sessions/{session_id}/finalize", headers={"X-Soma-Client-ID": "client-a"})
        _status, done = self.request(
            "GET", f"{base}/v1/sessions/{session_id}?wait=2", headers={"X-Soma-Client-ID": "client-a"}
        )
        self.assertEqual(done["status"], "done")
        self.assertEqual(done["text"], "first phrase second phrase")
        self.assertNotIn("partial_text", done, "a finished session reports text, not a partial")


if __name__ == "__main__":
    unittest.main()

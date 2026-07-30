"""Queue admission policy: live dictation outranks waiting media imports, and
the background backlog limit is only enforced when one is configured."""
import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

from soma_test_bootstrap import install_soma_imports

install_soma_imports()

import voice_server
from test_soma_voice_server import FakeBroker


class VoiceQueuePolicyTests(unittest.TestCase):
    def start_server(self, broker_delay=0.01, max_background_queue=0):
        broker = FakeBroker(delay=broker_delay)
        state = voice_server.VoiceServerState(
            token="secret", broker=broker, idle_seconds=1, completed_ttl=60,
            max_background_queue=max_background_queue,
        )
        server = ThreadingHTTPServer(("127.0.0.1", 0), voice_server.make_handler(state))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close()))
        return f"http://127.0.0.1:{server.server_address[1]}", broker

    def request(self, method, url, body=None, token="secret", headers=None):
        all_headers = dict(headers or {})
        if token is not None:
            all_headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(url, data=body, headers=all_headers, method=method)
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status, json.loads(response.read().decode())

    def wait_done(self, base, job_id):
        import time
        for _ in range(80):
            _status, payload = self.request("GET", f"{base}/v1/transcriptions/{job_id}")
            if payload["status"] == "done":
                return payload
            time.sleep(0.02)
        self.fail("job did not finish")

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

    def test_background_backlog_limit_is_enforced_when_configured(self):
        # Guards the reorder that skips the O(jobs) scan when no limit is set.
        base, _broker = self.start_server(broker_delay=0.3, max_background_queue=1)
        headers = {"X-Soma-Client-ID": "client-a", "Content-Type": "audio/flac", "X-Soma-Work-Class": "background"}
        for index in range(2):  # one runs, one waits and fills the reserve
            status, _payload = self.request(
                "POST", f"{base}/v1/transcriptions", body=f"media-{index}".encode(),
                headers={**headers, "X-Soma-Request-ID": f"media-{index}"},
            )
            self.assertEqual(status, 202)
        with self.assertRaises(urllib.error.HTTPError) as raised:
            self.request(
                "POST", f"{base}/v1/transcriptions", body=b"media-overflow",
                headers={**headers, "X-Soma-Request-ID": "media-overflow"},
            )
        payload = json.loads(raised.exception.read().decode())
        raised.exception.close()
        self.assertEqual(raised.exception.code, 429)
        self.assertEqual(payload["error"]["code"], "background_queue_full")

        # Live dictation is still admitted while background work is refused.
        status, _payload = self.request(
            "POST", f"{base}/v1/transcriptions", body=b"live",
            headers={"X-Soma-Client-ID": "client-a", "Content-Type": "audio/flac", "X-Soma-Request-ID": "live"},
        )
        self.assertEqual(status, 202)

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


if __name__ == "__main__":
    unittest.main()

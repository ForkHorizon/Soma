import unittest
import os
import json
import subprocess
import tempfile
from pathlib import Path
from unittest.mock import patch, MagicMock
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Soma"))
from soma_test_bootstrap import install_soma_imports
install_soma_imports()

from gateway.core import (
    _safe_text,
    _compact_result,
    _error_response,
    _ok_response,
    _parse_ports,
    NexusClient,
    NexusState
)

from gateway.graphify_adapter import GraphifyAdapter
from gateway.memory_store import MemoryStore

class TestGatewayCoreBasic(unittest.TestCase):

    def test_safe_text_string_no_truncation(self):
        text = "short string"
        self.assertEqual(_safe_text(text, 50), text)

    def test_safe_text_string_truncation(self):
        text = "very long string here"
        self.assertEqual(_safe_text(text, 9), "very long")

    def test_safe_text_dict_json_conversion(self):
        data = {"key": "value"}
        res = _safe_text(data, 100)
        self.assertEqual(res, json.dumps(data))

    def test_safe_text_dict_truncation(self):
        data = {"key": "value"}
        res = _safe_text(data, 5)
        self.assertEqual(res, json.dumps(data)[:5])

    def test_compact_result_basic(self):
        res_str = _compact_result("ok", "a summary")
        res = json.loads(res_str)
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["summary"], "a summary")
        self.assertEqual(res["evidence"], [])
        self.assertEqual(res["omitted"], {})
        self.assertEqual(res["next_calls"], [])

    def test_error_response_structure(self):
        res_str = _error_response("something failed", next_calls=["retry"])
        res = json.loads(res_str)
        self.assertEqual(res["status"], "error")
        self.assertEqual(res["summary"], "something failed")
        self.assertEqual(res["next_calls"], ["retry"])

    def test_ok_response_structure(self):
        res_str = _ok_response("all good", omitted={"key": "val"})
        res = json.loads(res_str)
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["summary"], "all good")
        self.assertEqual(res["omitted"], {"key": "val"})

    @patch.dict(os.environ, {"NEXUS_PORT": "8082", "NEXUS_PORTS": "8083,8084"}, clear=True)
    def test_parse_ports_from_env(self):
        ports = _parse_ports()
        self.assertEqual(ports[:3], [8082, 8083, 8084])
        self.assertIn(8090, ports)

    def test_nexus_client_url_default(self):
        client = NexusClient(ports=[8085])
        client.state = NexusState()
        self.assertEqual(client._url(), "http://127.0.0.1:8085/")

    def test_nexus_client_url_override(self):
        client = NexusClient(ports=[8085])
        client.state = NexusState()
        client.state.port = 8086
        self.assertEqual(client._url(8087), "http://127.0.0.1:8087/")

if __name__ == '__main__':
    unittest.main()

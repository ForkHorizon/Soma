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

class TestMemoryStore(unittest.TestCase):

    def test_memory_store_project_dir_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch('gateway.memory_store.SOMA_MEMORY_DIR', Path(tmp)):
                store = MemoryStore()
                p_dir = store.project_dir(None)
                self.assertEqual(p_dir, Path(tmp) / "default")
                self.assertTrue(p_dir.exists())

    def test_memory_store_project_dir_custom(self):
        with tempfile.TemporaryDirectory() as tmp:
            custom_project = Path(tmp) / "my_project"
            store = MemoryStore()
            p_dir = store.project_dir(str(custom_project))
            self.assertEqual(p_dir, custom_project / ".soma")
            self.assertTrue(p_dir.exists())

    def test_memory_store_load_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            custom_project = Path(tmp) / "my_project"
            store = MemoryStore()
            mem = store.load(str(custom_project))
            self.assertEqual(mem, {"notes": [], "known_issues": [], "patterns": []})

    def test_memory_store_load_with_legacy_memory(self):
        with tempfile.TemporaryDirectory() as tmp:
            custom_project = Path(tmp) / "my_project"
            store = MemoryStore()

            p_dir = store.project_dir(str(custom_project))
            (p_dir / "memory.json").write_text('{"notes": [{"text": "legacy note"}], "patterns": ["pattern1"]}')

            mem = store.load(str(custom_project))
            self.assertEqual(len(mem["notes"]), 1)
            self.assertEqual(mem["notes"][0]["text"], "legacy note")
            self.assertIn("pattern1", mem["patterns"])

    def test_memory_store_load_with_known_issues(self):
        with tempfile.TemporaryDirectory() as tmp:
            custom_project = Path(tmp) / "my_project"
            store = MemoryStore()

            p_dir = store.project_dir(str(custom_project))
            (p_dir / "known_issues.json").write_text('[{"text": "issue 1"}]')

            mem = store.load(str(custom_project))
            self.assertEqual(len(mem["known_issues"]), 1)
            self.assertEqual(mem["known_issues"][0]["text"], "issue 1")

    def test_memory_store_load_with_known_issues_dict(self):
        with tempfile.TemporaryDirectory() as tmp:
            custom_project = Path(tmp) / "my_project"
            store = MemoryStore()

            p_dir = store.project_dir(str(custom_project))
            (p_dir / "known_issues.json").write_text('{"known_issues": [{"text": "dict issue"}]}')

            mem = store.load(str(custom_project))
            self.assertEqual(len(mem["known_issues"]), 1)
            self.assertEqual(mem["known_issues"][0]["text"], "dict issue")

if __name__ == '__main__':
    unittest.main()

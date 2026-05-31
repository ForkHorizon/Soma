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
    _packet_budget,
    _analysis_depth,
    _evidence_summary,
    _enforce_packet_budget,
    get_active_project_root,
    TOKEN_BUDGETS,
    DEFAULT_TOKEN_BUDGET
)

class TestGatewayCoreAdvanced(unittest.TestCase):

    def test_packet_budget_valid(self):
        self.assertEqual(_packet_budget("fast"), "fast")
        self.assertEqual(_packet_budget("deep"), "deep")

    def test_packet_budget_invalid(self):
        self.assertEqual(_packet_budget("invalid_budget"), DEFAULT_TOKEN_BUDGET)

    def test_analysis_depth_valid(self):
        self.assertEqual(_analysis_depth("analyst"), "analyst")

    def test_analysis_depth_invalid(self):
        self.assertEqual(_analysis_depth("unknown_depth"), "deterministic")

    def test_evidence_summary_truncates(self):
        items = [{"path": f"f{i}", "kind": "file", "reason": f"r{i}"} for i in range(10)]
        summary = _evidence_summary(items, limit=3)
        self.assertEqual(len(summary), 3)
        self.assertEqual(summary[0]["path"], "f0")

    def test_evidence_summary_symbols_truncated(self):
        item = {"path": "f1", "kind": "file", "reason": "r1", "symbols": ["s" + str(i) for i in range(10)]}
        summary = _evidence_summary([item])
        self.assertEqual(len(summary[0]["symbols"]), 6)

    def test_evidence_summary_empty(self):
        self.assertEqual(_evidence_summary([]), [])

    @patch('gateway.core.estimate_tokens')
    def test_enforce_packet_budget_under_budget(self, mock_estimate):
        mock_estimate.return_value = 100
        packet = "some small packet"
        result = _enforce_packet_budget("my goal", {}, packet, "fast")
        self.assertEqual(result, packet)

    @patch('gateway.core.estimate_tokens')
    def test_enforce_packet_budget_over_budget(self, mock_estimate):
        # We need it to be over budget, so it enters the fallback logic
        # Then inside the fallback logic it estimates the fallback packet,
        # so we mock side_effect to return > budget then < budget
        mock_estimate.side_effect = [999999, 100]
        bundle = {
            "evidence_items": [{"path": "f1", "kind": "file", "reason": "r1"}],
            "omitted_context": {"key": "value"}
        }
        result = _enforce_packet_budget("my goal", bundle, "some massive packet", "fast")

        self.assertIn("Goal:", result)
        self.assertIn("my goal", result)
        self.assertIn("- f1 [file]: r1", result)
        self.assertIn("- key: value", result)

    @patch('os.path.isdir')
    @patch.dict(os.environ, {"SOMA_PROJECT_ROOT": "/custom/path"}, clear=True)
    def test_get_active_project_root_env(self, mock_isdir):
        mock_isdir.return_value = True

        with patch('scout_pipeline.normalize_path', side_effect=lambda x: x):
            self.assertEqual(get_active_project_root(), "/custom/path")

if __name__ == '__main__':
    unittest.main()

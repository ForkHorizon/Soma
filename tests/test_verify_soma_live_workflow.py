import argparse
import asyncio
import json
import unittest
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Soma"))

import verify_soma_live_workflow as verifier


class FakeTool:
    def __init__(self, name):
        self.name = name


class FakeToolsResult:
    def __init__(self, names):
        self.tools = [FakeTool(name) for name in names]


class FakeText:
    def __init__(self, text):
        self.text = text


class FakeToolResult:
    def __init__(self, payload):
        self.content = [FakeText(json.dumps(payload))]


class FakeSession:
    def __init__(self, responses, tools=None):
        self.responses = responses
        self.tools = tools or verifier.EXPECTED_TOOLS
        self.calls = []

    async def list_tools(self):
        return FakeToolsResult(self.tools)

    async def call_tool(self, name, params):
        self.calls.append((name, params))
        payload = self.responses[name]
        if callable(payload):
            payload = payload(params)
        return FakeToolResult(payload)


def args(**overrides):
    defaults = {
        "project_root": "/tmp/project",
        "goal": "debug Unity",
        "inspect_id": None,
        "live_unity": True,
        "run_apply": True,
        "cleanup_apply": True,
        "apply_path": verifier.DEFAULT_APPLY_PATH,
        "apply_content": verifier.DEFAULT_APPLY_CONTENT,
    }
    defaults.update(overrides)
    return argparse.Namespace(**defaults)


class VerifySomaLiveWorkflowTests(unittest.TestCase):
    def test_live_workflow_auto_inspects_applies_and_cleans_up(self):
        session = FakeSession(
            {
                "soma_get_map": {
                    "status": "ok",
                    "summary": "map",
                    "map": {
                        "graph": {"available": True, "project_graph_available": True, "stale": False},
                        "nexus": {"connected": True, "port": 8081, "session_id": "abc"},
                    },
                    "omitted": {},
                },
                "soma_prepare_context": {"status": "ok", "summary": "packet", "evidence": [{}], "omitted": {}},
                "soma_scene": {"status": "ok", "summary": "scene", "scene": {"roots": [{"name": "Main", "instance_id": 123}]}, "omitted": {}},
                "soma_inspect": {"status": "ok", "summary": "inspect", "omitted": {}},
                "soma_delta": {"status": "ok", "summary": "delta", "omitted": {}},
                "soma_apply": {"status": "ok", "summary": "apply", "omitted": {}},
                "soma_execute": {"status": "ok", "summary": "cleanup", "omitted": {}},
            }
        )

        report = asyncio.run(verifier.verify_session(session, args()))

        self.assertEqual(report["status"], "ok")
        self.assertEqual(report["calls"]["soma_inspect"]["instance_id"], 123)
        self.assertEqual(report["calls"]["soma_apply"]["path"], verifier.DEFAULT_APPLY_PATH)
        self.assertEqual(report["calls"]["cleanup_apply"]["status"], "ok")
        self.assertIn(("soma_inspect", {"instance_id": 123}), session.calls)
        self.assertIn(
            ("soma_execute", {"requests": [{"method": "delete_asset", "params": {"path": verifier.DEFAULT_APPLY_PATH}}]}),
            session.calls,
        )

    def test_live_workflow_degrades_when_nexus_is_offline(self):
        session = FakeSession(
            {
                "soma_get_map": {
                    "status": "ok",
                    "summary": "map",
                    "map": {
                        "graph": {"available": True, "project_graph_available": True, "stale": False},
                        "nexus": {"connected": False},
                    },
                    "omitted": {},
                },
                "soma_prepare_context": {"status": "ok", "summary": "packet", "omitted": {}},
                "soma_scene": {"status": "error", "summary": "Nexus Unity not connected.", "omitted": {}},
                "soma_delta": {"status": "ok", "summary": "delta", "omitted": {}},
            }
        )

        report = asyncio.run(verifier.verify_session(session, args(run_apply=False, cleanup_apply=False)))

        self.assertEqual(report["status"], "degraded")
        self.assertIn("nexus_offline", report["issues"])
        self.assertIn("live_scene_failed", report["issues"])
        self.assertIn("inspect_id_not_found", report["issues"])
        self.assertEqual(report["calls"]["soma_apply"]["status"], "skipped")

    def test_tool_catalog_with_unity_tool_is_degraded(self):
        session = FakeSession(
            {
                "soma_get_map": {"status": "ok", "summary": "map", "map": {}, "omitted": {}},
                "soma_prepare_context": {"status": "ok", "summary": "packet", "omitted": {}},
                "soma_scene": {"status": "ok", "summary": "scene", "scene": {"instance_id": 1}, "omitted": {}},
                "soma_delta": {"status": "ok", "summary": "delta", "omitted": {}},
            },
            tools=verifier.EXPECTED_TOOLS + ["unity_get_editor_state"],
        )

        report = asyncio.run(verifier.verify_session(session, args(live_unity=False, run_apply=False, cleanup_apply=False)))

        self.assertEqual(report["status"], "degraded")
        self.assertIn("unity_tools_exposed", report["issues"])
        self.assertEqual(report["tools"]["unity_exposed"], ["unity_get_editor_state"])

    def test_live_apply_is_skipped_for_wrong_nexus_project(self):
        session = FakeSession(
            {
                "soma_get_map": {
                    "status": "ok",
                    "summary": "map",
                    "map": {
                        "graph": {"available": True, "project_graph_available": True, "stale": False},
                        "nexus": {"connected": True, "project_path": "/tmp/other-project"},
                    },
                    "omitted": {},
                },
                "soma_prepare_context": {"status": "ok", "summary": "packet", "omitted": {}},
                "soma_scene": {"status": "ok", "summary": "scene", "scene": {"roots": [{"instance_id": 321}]}, "omitted": {}},
                "soma_inspect": {"status": "ok", "summary": "inspect", "omitted": {}},
                "soma_delta": {"status": "ok", "summary": "delta", "omitted": {}},
            }
        )

        report = asyncio.run(verifier.verify_session(session, args(project_root="/tmp/project")))

        self.assertEqual(report["status"], "degraded")
        self.assertIn("wrong_project", report["issues"])
        self.assertEqual(report["calls"]["soma_apply"]["status"], "skipped")
        self.assertEqual(report["calls"]["cleanup_apply"]["status"], "skipped")
        self.assertFalse(any(call[0] == "soma_apply" for call in session.calls))


if __name__ == "__main__":
    unittest.main()

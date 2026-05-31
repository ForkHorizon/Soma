import asyncio
import contextlib
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Soma"))

import scout_pipeline
import scout_pipeline_module.llama as llama
from scout_pipeline_module.ranker import pinned_evidence_ids
import soma_logger


class FakeHTTPResponse:
    def __init__(self, body: str):
        self.body = body.encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self):
        return self.body


def cloud_referee_env():
    return {
        "SOMA_CLOUD_REFEREE_PROVIDER": "openai",
        "SOMA_OPENAI_API_KEY": "test-key",
        "SOMA_OPENAI_REFEREE_MODEL": "gpt-test-referee",
        "SOMA_CLOUD_REFEREE_POLICY": "always",
    }


def cloud_referee_response(payload=None):
    payload = payload or {
        "status": "degraded",
        "missing_evidence": ["changelog"],
        "recommended_additions": ["graphify --version"],
        "warnings": ["Missing version evidence."],
        "notes": ["Ask for the exact installed graph version."],
    }
    return FakeHTTPResponse(json.dumps({"output_text": json.dumps(payload)}))


def compact_referee_evidence():
    return [
        {
            "path": "/repo/Soma/gateway/graphify_adapter.py",
            "kind": "source",
            "reason": "Graph integration",
            "preview": "SECRET_SOURCE_BODY",
            "symbols": ["GraphifyAdapter"],
        }
    ]


def release_planner_response():
    content = {
        "task_type": "release_readiness",
        "target_scope": "unity_package",
        "scope_hints": ["Assets/NexusUnity", "Nexus Unity"],
        "required_evidence": [
            "package_manifest",
            "readme",
            "license",
            "changelog",
            "tests",
            "core_entrypoints",
        ],
        "excluded_context": [
            "Library",
            ".soma",
            "ProjectSettings",
            "AutoSavedScene.unity",
            "Assets/Plugins/Android",
        ],
        "expected_packet_style": "readiness_review_packet",
        "confidence": 0.91,
        "warnings": [],
    }
    return {"message": {"content": json.dumps(content)}}


def ok_referee_response():
    content = {
        "status": "ok",
        "missing_evidence": [],
        "bad_evidence": [],
        "recommended_additions": [],
        "warnings": [],
    }
    return {"message": {"content": json.dumps(content)}}


def make_nexus_unity_fixture(root, *, version="1.0.0", include_noise=False):
    package_root = root / "Assets" / "NexusUnity"
    (package_root / "Editor" / "Tests").mkdir(parents=True)
    (package_root / "Runtime").mkdir(parents=True)
    write_wrapper_project_files(root, include_noise=include_noise)
    write_nexus_package_files(package_root, version=version)
    return package_root


def write_wrapper_project_files(root, *, include_noise=False):
    (root / "ProjectSettings").mkdir(exist_ok=True)
    (root / "Assets").mkdir(exist_ok=True)
    (root / "AutoSavedScene.unity").write_text("Main Camera\nm_Name: Test Wrapper Scene\n")
    (root / "ProjectSettings" / "ProjectSettings.asset").write_text(
        "PlayerSettings:\n  applicationIdentifier:\n    Android: com.UnityTechnologies.wrapper\n"
    )
    (root / "package.json").write_text(
        '{"name":"com.wrapper.host","displayName":"Nexus Unity Wrapper Host"}\n'
    )
    (root / "README.md").write_text("# Wrapper Host\n\nThis project only exists to test the package.\n")
    if include_noise:
        write_wrapper_noise_files(root)


def write_wrapper_noise_files(root):
    (root / "Assets" / "Plugins" / "Android").mkdir(parents=True)
    (root / "Assets" / "Visual" / "Sprites" / "Icon").mkdir(parents=True)
    (root / "Library" / "PackageCache" / "com.noise").mkdir(parents=True)
    (root / ".soma" / "graphify-out").mkdir(parents=True)
    (root / "Assets" / "Plugins" / "Android" / "AndroidManifest.xml").write_text(
        '<manifest><application android:icon="@mipmap/app_icon" /></manifest>\n'
    )
    (root / "Assets" / "Visual" / "Sprites" / "Icon" / "ICON5.png.meta").write_text(
        "guid: wrappericon\nTextureImporter:\n  textureType: 8\n"
    )
    (root / "Library" / "PackageCache" / "com.noise" / "package.json").write_text(
        '{"name":"com.generated.noise","displayName":"Generated Nexus Unity Noise"}\n'
    )
    (root / ".soma" / "graphify-out" / "graph.json").write_text("{}\n")


def write_nexus_package_files(package_root, *, version):
    (package_root / "package.json").write_text(
        '{"name":"com.forkhorizon.nexus.unity","displayName":"Nexus Unity",'
        f'"version":"{version}","license":"GPL-3.0-only",'
        '"description":"Open source Unity MCP bridge and editor automation package."}\n'
    )
    (package_root / "README.md").write_text(
        "# Nexus Unity\n\nPublic package docs, setup, MCP bridge usage, and release notes.\n"
    )
    (package_root / "LICENSE.md").write_text("GPL-3.0-only\n")
    (package_root / "CHANGELOG.md").write_text(f"## {version}\n- Prepare public release.\n")
    (package_root / "DOCUMENTATION.MD").write_text("# API\n\nDocuments tools and setup flows.\n")
    (package_root / "Editor" / "MCPServer.cs").write_text(
        "namespace NexusUnity.Editor { public static class MCPServer { public static void Start() {} } }\n"
    )
    (package_root / "Editor" / "MCPServerMethods.cs").write_text(
        "namespace NexusUnity.Editor { public static class MCPServerMethods { public static void Register() {} } }\n"
    )
    (package_root / "Runtime" / "NexusUnityClient.cs").write_text(
        "namespace NexusUnity.Runtime { public sealed class NexusUnityClient {} }\n"
    )
    (package_root / "Editor" / "Tests" / "OpenSourceReadinessTests.cs").write_text(
        "public sealed class OpenSourceReadinessTests {}\n"
    )


def wrapper_graphify_result(root):
    return {
        "graphs": [str(root / ".soma" / "graphify-out" / "graph.json")],
        "answers": [{"graph": "wrapper", "answer": "Raw BFS mentions AutoSavedScene and Android icon noise."}],
        "warnings": [],
        "project_only": True,
    }


def normalized_evidence_paths(bundle):
    return [item["path"].replace("\\", "/") for item in bundle["evidence_items"]]


def focused_evidence_from_packet(packet):
    return packet.split("Focused Evidence:", 1)[1].split("Expected answer:", 1)[0]


def assert_nexus_package_evidence(testcase, bundle):
    evidence_paths = normalized_evidence_paths(bundle)
    testcase.assertTrue(bundle["preflight"]["focus_root"].replace("\\", "/").endswith("/Assets/NexusUnity"))
    testcase.assertTrue(any(path.endswith("/Assets/NexusUnity/package.json") for path in evidence_paths))
    testcase.assertTrue(any(path.endswith("/Assets/NexusUnity/README.md") for path in evidence_paths))
    testcase.assertTrue(any(path.endswith("/Assets/NexusUnity/LICENSE.md") for path in evidence_paths))
    testcase.assertFalse(any("AutoSavedScene.unity" in path for path in evidence_paths))
    testcase.assertFalse(any("ProjectSettings.asset" in path for path in evidence_paths))
    testcase.assertFalse(any("AndroidManifest.xml" in path for path in evidence_paths))


def assert_planned_release_packet(testcase, bundle):
    packet = bundle["codex_packet"]
    focused_evidence = focused_evidence_from_packet(packet)
    evidence_paths = normalized_evidence_paths(bundle)
    assert_nexus_package_evidence(testcase, bundle)
    testcase.assertTrue(any(path.endswith("/Assets/NexusUnity/CHANGELOG.md") for path in evidence_paths))
    testcase.assertTrue(any(path.endswith("/Assets/NexusUnity/Editor/MCPServer.cs") for path in evidence_paths))
    testcase.assertEqual(bundle["collection_plan_source"], "local_model")
    testcase.assertEqual(bundle["collection_plan"]["task_type"], "release_readiness")
    testcase.assertIn("Collection Plan:", packet)
    testcase.assertIn("Focused Evidence:", packet)
    testcase.assertIn("Assets/NexusUnity/package.json", packet)
    testcase.assertNotIn("Git status:", packet)
    testcase.assertNotIn("Token budget:", packet)
    testcase.assertNotIn("Graph context (from Graphify):", packet)
    testcase.assertNotIn("Raw BFS", packet)
    testcase.assertNotIn("AutoSavedScene.unity", focused_evidence)
    testcase.assertNotIn("ProjectSettings.asset", focused_evidence)
    testcase.assertNotIn("AndroidManifest.xml", focused_evidence)
    testcase.assertFalse(bundle["evidence_quality"].get("excluded_context_selected"))


class ScoutPipelineTestCase(unittest.TestCase):
    def run_gather(self, prompt, project_root, *extra_args):
        defaults = ("balanced", False, "deterministic", "standard", "off")
        if len(extra_args) < len(defaults):
            extra_args = tuple(extra_args) + defaults[len(extra_args):]
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            asyncio.run(
                scout_pipeline.run_gather(
                    prompt,
                    str(project_root),
                    "[]",
                    *extra_args,
                )
            )
        return json.loads(stdout.getvalue())

    def make_repo(self):
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "Soma").mkdir()
        (root / "Soma" / "relay.py").write_text("MODEL = 'gemma4:e4b'\n\ndef relay():\n    return 'ok'\n")
        (root / "Soma" / "ContentView.swift").write_text("import SwiftUI\n\nstruct ContentView: View {\n    var body: some View { Text(\"Soma\") }\n}\n")
        (root / "Package.swift").write_text("// swift-tools-version: 5.9\n")
        (root / "ollama_logs.txt").write_text("INFO server started\n")
        (root / "README.md").write_text("old readme\n")
        subprocess.run(["git", "init"], cwd=root, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-m", "init"], cwd=root, check=True, capture_output=True)
        (root / "Soma" / "relay.py").write_text("MODEL = 'gemma4:e4b'\n\ndef relay():\n    return 'fast'\n")
        (root / "README.md").write_text("new readme\n")
        (root / ".DS_Store").write_text("noise")
        (root / "Soma" / "__pycache__").mkdir()
        (root / "Soma" / "__pycache__" / "relay.cpython-313.pyc").write_bytes(b"noise")
        return tmp, root

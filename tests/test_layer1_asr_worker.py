import importlib.util
import json
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "layer1_asr_worker", Path(__file__).parents[1] / "Scripts" / "layer1_asr_worker.py"
)
worker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(worker)


def test_json_payload_is_preserved():
    payload = worker.parse_payload('{"text":"я я думаю","words":[]}')
    assert payload == {"text": "я я думаю", "words": []}


def test_non_json_output_is_left_as_raw_text():
    assert worker.parse_payload("я я думаю\n") is None


def test_empty_output_is_explicit_empty_transcript():
    assert worker.parse_payload("   ") == {"text": ""}


def test_child_environment_exposes_homebrew_tools_to_decoders():
    environment = worker.child_environment({"PATH": "/usr/bin"})
    assert environment["PATH"].startswith("/opt/homebrew/bin:/opt/homebrew/sbin:")

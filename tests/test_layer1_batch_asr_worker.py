import importlib.util
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).parents[1]
WORKER = ROOT / "Scripts" / "layer1_batch_asr_worker.py"


def test_batch_worker_forwards_jsonl_and_manifest(tmp_path):
    manifest = tmp_path / "manifest.jsonl"
    manifest.write_text(json.dumps({"id": "run-1", "file": "a.wav", "audio": "/tmp/a.wav"}) + "\n")
    command_script = tmp_path / "fake_decoder.py"
    command_script.write_text(
        "import json, sys\n"
        "row = json.loads(open(sys.argv[1]).readline())\n"
        "print(json.dumps({'id': row['id'], 'file': row['file'], 'text': 'ok', 'words': [], 'version': 'test'}))\n"
    )
    command = f"{sys.executable} {command_script} {{manifest}}".replace(" ", "\x1f")
    result = subprocess.run([
        sys.executable, str(WORKER), "--manifest", str(manifest), "--model", "fake",
        "--command", command,
    ], capture_output=True, text=True, check=False)
    assert result.returncode == 0
    assert json.loads(result.stdout)["id"] == "run-1"


def test_batch_worker_fails_when_child_fails(tmp_path):
    manifest = tmp_path / "manifest.jsonl"
    manifest.write_text(json.dumps({"id": "run-1", "file": "a.wav", "audio": "/tmp/a.wav"}) + "\n")
    command = f"{sys.executable} -c import sys;sys.exit(7)".replace(" ", "\x1f")
    result = subprocess.run([
        sys.executable, str(WORKER), "--manifest", str(manifest), "--model", "fake",
        "--command", command,
    ], capture_output=True, text=True, check=False)
    assert result.returncode != 0

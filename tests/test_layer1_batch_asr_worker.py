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
    result = subprocess.run(
        [
            sys.executable,
            str(WORKER),
            "--manifest",
            str(manifest),
            "--model",
            "fake",
            "--command",
            command,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0
    assert json.loads(result.stdout)["id"] == "run-1"


def test_batch_worker_fails_when_child_fails(tmp_path):
    manifest = tmp_path / "manifest.jsonl"
    manifest.write_text(json.dumps({"id": "run-1", "file": "a.wav", "audio": "/tmp/a.wav"}) + "\n")
    command = f"{sys.executable} -c import sys;sys.exit(7)".replace(" ", "\x1f")
    result = subprocess.run(
        [
            sys.executable,
            str(WORKER),
            "--manifest",
            str(manifest),
            "--model",
            "fake",
            "--command",
            command,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0


def test_batch_worker_terminates_child_process_group_on_sigterm(tmp_path):
    import os
    import signal
    import time

    manifest = tmp_path / "manifest.jsonl"
    manifest.write_text(json.dumps({"id": "run-1", "file": "a.wav", "audio": "/tmp/a.wav"}) + "\n")
    pid_file = tmp_path / "child.pid"
    command_script = tmp_path / "hanging_decoder.py"
    command_script.write_text(
        "import os, time, sys\n"
        f"with open(r'{pid_file}', 'w') as f: f.write(str(os.getpid()))\n"
        "while True:\n"
        "    time.sleep(0.1)\n"
    )
    command = f"{sys.executable} {command_script} {{manifest}}".replace(" ", "\x1f")
    proc = subprocess.Popen(
        [
            sys.executable,
            str(WORKER),
            "--manifest",
            str(manifest),
            "--model",
            "fake",
            "--command",
            command,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    for _ in range(50):
        if pid_file.exists():
            break
        time.sleep(0.05)
    assert pid_file.exists()
    child_pid = int(pid_file.read_text().strip())
    os.kill(child_pid, 0)
    proc.send_signal(signal.SIGTERM)
    proc.wait(timeout=5)
    time.sleep(0.2)
    try:
        os.kill(child_pid, 0)
        is_alive = True
    except OSError:
        is_alive = False
    assert not is_alive, f"Child process {child_pid} was not terminated on SIGTERM"


def test_decode_hf_batch_vosk_multi_phrase_accumulation(monkeypatch):
    from unittest.mock import MagicMock

    mock_np = MagicMock()
    mock_np.clip.return_value.__mul__.return_value.astype.return_value.tobytes.return_value = (
        b"\x00" * 16000
    )
    mock_vosk = MagicMock()
    mock_model = MagicMock()
    mock_rec = MagicMock()
    mock_vosk.Model.return_value = mock_model
    mock_vosk.KaldiRecognizer.return_value = mock_rec

    mock_rec.AcceptWaveform.side_effect = [True, False]
    mock_rec.Result.return_value = json.dumps(
        {
            "text": "первая фраза",
            "result": [
                {"word": "первая", "start": 0.1, "end": 0.5},
                {"word": "фраза", "start": 0.6, "end": 1.0},
            ],
        }
    )
    mock_rec.FinalResult.return_value = json.dumps(
        {
            "text": "вторая фраза",
            "result": [
                {"word": "вторая", "start": 1.5, "end": 2.0},
                {"word": "фраза", "start": 2.1, "end": 2.5},
            ],
        }
    )

    monkeypatch.setitem(sys.modules, "numpy", mock_np)
    monkeypatch.setitem(sys.modules, "vosk", mock_vosk)
    decode_hf_batch_spec = importlib.util.spec_from_file_location(
        "decode_hf_batch", Path(__file__).parents[1] / "Scripts" / "layer1" / "decode_hf_batch.py"
    )
    decode_hf_batch = importlib.util.module_from_spec(decode_hf_batch_spec)
    decode_hf_batch_spec.loader.exec_module(decode_hf_batch)

    monkeypatch.setattr(decode_hf_batch, "load16", lambda p: [0.0] * 8000)

    rows = list(
        decode_hf_batch.run_vosk(
            [{"id": "run-1", "file": "a.wav", "audio": "/dummy/a.wav"}]
        )
    )
    assert len(rows) == 1
    row, text, words, version = rows[0]
    assert row["id"] == "run-1"
    assert text == "первая фраза вторая фраза"
    assert len(words) == 4
    assert version == "vosk-small-ru-0.22"

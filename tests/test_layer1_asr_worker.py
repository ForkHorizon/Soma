import os
import importlib.util
import json
import signal
import subprocess
import sys
import time
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


def test_single_worker_terminates_child_process_group_on_sigterm(tmp_path):
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"RIFF....WAVE")
    pid_file = tmp_path / "child.pid"
    command_script = tmp_path / "hanging_decoder.py"
    command_script.write_text(
        "import os, time, sys\n"
        f"with open(r'{pid_file}', 'w') as f: f.write(str(os.getpid()))\n"
        "while True:\n"
        "    time.sleep(0.1)\n"
    )
    command = f"{sys.executable} {command_script} {{audio}}".replace(" ", "\x1f")
    worker_script = Path(__file__).parents[1] / "Scripts" / "layer1_asr_worker.py"
    proc = subprocess.Popen(
        [
            sys.executable,
            str(worker_script),
            "--audio",
            str(audio),
            "--audio-hash",
            "fakehash",
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


def test_decode_hf_load16_stereo_downmix(monkeypatch):
    from unittest.mock import MagicMock

    mock_torchaudio = MagicMock()
    stereo_tensor = MagicMock()
    stereo_tensor.shape = (2, 1000)
    mono_tensor = MagicMock()
    mono_tensor.squeeze.return_value.numpy.return_value = "mono_1d_array"
    stereo_tensor.mean.return_value = mono_tensor
    mock_torchaudio.load.return_value = (stereo_tensor, 16000)

    monkeypatch.setitem(sys.modules, "torchaudio", mock_torchaudio)

    decode_hf_spec = importlib.util.spec_from_file_location(
        "decode_hf", Path(__file__).parents[1] / "Scripts" / "layer1" / "decode_hf.py"
    )
    decode_hf = importlib.util.module_from_spec(decode_hf_spec)
    decode_hf_spec.loader.exec_module(decode_hf)

    result = decode_hf.load16("/dummy/stereo.wav")
    stereo_tensor.mean.assert_called_once_with(dim=0, keepdim=True)
    assert result == "mono_1d_array"


def test_decode_hf_vosk_multi_phrase_accumulation(monkeypatch):
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

    # AcceptWaveform returns True on chunk 0, False on chunk 1
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
    decode_hf_spec = importlib.util.spec_from_file_location(
        "decode_hf", Path(__file__).parents[1] / "Scripts" / "layer1" / "decode_hf.py"
    )
    decode_hf = importlib.util.module_from_spec(decode_hf_spec)
    decode_hf_spec.loader.exec_module(decode_hf)

    monkeypatch.setattr(decode_hf, "load16", lambda p: [0.0] * 8000)

    text, words, version = decode_hf.decode_vosk("/dummy/audio.wav")
    assert text == "первая фраза вторая фраза"
    assert len(words) == 4
    assert words[0]["word"] == "первая"
    assert words[2]["word"] == "вторая"
    assert version == "vosk-small-ru-0.22"

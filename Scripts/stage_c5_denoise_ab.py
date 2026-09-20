#!/usr/bin/env python3
"""Stage C5: denoise A/B — preprocess audio, then decode with the champion config.

Read-only on originals: denoised WAVs go to GroundTruth/experiments/denoised/<filter>/,
decodes to experiments/decodes-stage-c5-<filter>.jsonl. Champion baseline comes
from the main decode cache (w-bo-t20-n10-v1); it is never re-decoded.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

from ground_truth_paths import LEGACY_ROOT

HOME = Path.home()
GT = LEGACY_ROOT
RECS = HOME / "Library/Application Support/Soma/VoiceRecordings"
VENV_ROOT = HOME / "Daliys/AI_Test_Playground/asr-engines"
WORKER = Path(__file__).resolve().parent.parent / "Scripts" / "ground_truth_worker.py"
DEN_VENV = GT / "experiments/denoise-venv"

FILTERS = ["dfn3", "rnnoise", "noisereduce", "fbdenoiser"]


def ensure_denoise_venv() -> None:
    if (DEN_VENV / "bin" / "python").exists():
        return
    print("creating denoise venv …", flush=True)
    subprocess.run([sys.executable, "-m", "venv", str(DEN_VENV)], check=True)
    subprocess.run([str(DEN_VENV / "bin" / "pip"), "install", "--quiet", "--upgrade", "pip"], check=True)


def pip_install(*packages: str) -> None:
    subprocess.run([str(DEN_VENV / "bin" / "pip"), "install", "--quiet", *packages], check=True)


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def build_file_list() -> list[str]:
    """Gold (human references) + hallucination-suspect files; originals only."""
    files: list[str] = []
    gold = read_jsonl(GT / "gold.jsonl")
    files.extend(str(RECS / r["file"]) for r in gold)
    suspects: set[str] = set()
    for row in read_jsonl(GT / "experiments/cleaned-stage7-v1-w-greedy.jsonl"):
        if row["cleaned"] != row["verbatim"]:
            suspects.add(row["file"])
    for row in read_jsonl(GT / "experiments/empty-stage8.jsonl"):
        suspects.add(row["file"])
    files.extend(str(RECS / f) for f in sorted(suspects))
    seen, unique = set(), []
    for f in files:
        if f not in seen:
            seen.add(f)
            unique.append(f)
    missing = [f for f in unique if not Path(f).exists()]
    if missing:
        raise SystemExit(f"missing {len(missing)} wav files, e.g. {missing[:3]}")
    return unique


def denoise_all(filter_name: str, files: list[str], out_root: Path) -> Path:
    """Produce denoised copies under out_root/<filter>/rec-*.wav (resampled 16k mono)."""
    out_dir = out_root / filter_name
    done_marker = out_dir / ".complete"
    if done_marker.exists():
        print(f"[{filter_name}] already denoised ({len(files)} files)", flush=True)
        return out_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    script = out_root / f"denoise_{filter_name}.py"
    script.write_text(DENOISE_SCRIPTS[filter_name], encoding="utf-8")
    started = time.perf_counter()
    proc = subprocess.run(
        [str(DEN_VENV / "bin" / "python"), str(script), out_dir, *files],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"denoise {filter_name} failed:\n{proc.stdout[-2000:]}\n{proc.stderr[-2000:]}")
    produced = sum(1 for _ in out_dir.glob("rec-*.wav"))
    if produced < len(files):
        raise RuntimeError(f"[{filter_name}] produced {produced}/{len(files)} files")
    done_marker.write_text(str(len(files)))
    print(f"[{filter_name}] denoised {produced} files in {time.perf_counter() - started:.0f}s", flush=True)
    return out_dir


DENOISE_SCRIPTS = {
    "dfn3": """
import sys
from pathlib import Path
out_dir = Path(sys.argv[1]); files = sys.argv[2:]
import torch, soundfile as sf
from df.enhance import enhance, init_df
model, df_state, _ = init_df()
sr = df_state.sr()
for f in files:
    src = Path(f); dst = out_dir / src.name
    if dst.exists(): continue
    audio, _ = sf.read(str(src), dtype="float32")
    if getattr(audio, "ndim", 1) > 1: audio = audio.mean(axis=1)
    enhanced = enhance(model, df_state, audio)
    sf.write(str(dst), enhanced, sr)
    print(".", end="", flush=True)
print(" done")
""",
    "rnnoise": """
import subprocess, sys
from pathlib import Path
out_dir = Path(sys.argv[1]); files = sys.argv[2:]
import numpy as np, soundfile as sf
# rnnoise via the 'rnnoise' pip wheel if present, else ffmpeg's arnnd filter fallback
try:
    import rnnoise
    have_python = True
except ImportError:
    have_python = False
for f in files:
    src = Path(f); dst = out_dir / src.name
    if dst.exists(): continue
    if have_python:
        import wave
        with wave.open(str(src)) as w:
            rate = w.getframerate(); raw = w.readframes(w.getnframes())
        data = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
        if data.ndim > 1: data = data.mean(axis=1)
        den = rnnoise.filter(data, rate)
        sf.write(str(dst), np.clip(den, -1, 1), rate)
    else:
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
                        "-af", "arnndn=m=/opt/homebrew/share/rnnoise/models/std.rnnn",
                        "-ar", "16000", "-ac", "1", str(dst)], check=True)
    print(".", end="", flush=True)
print(" done")
""",
    "noisereduce": """
import sys
from pathlib import Path
out_dir = Path(sys.argv[1]); files = sys.argv[2:]
import numpy as np, soundfile as sf
import noisereduce as nr
for f in files:
    src = Path(f); dst = out_dir / src.name
    if dst.exists(): continue
    data, rate = sf.read(str(src), dtype="float32", always_2d=True)
    mono = data.mean(axis=1)
    den = nr.reduce_noise(y=mono, sr=rate)
    sf.write(str(dst), den, rate)
    print(".", end="", flush=True)
print(" done")
""",
    "fbdenoiser": """
import sys, torch
from pathlib import Path
out_dir = Path(sys.argv[1]); files = sys.argv[2:]
import soundfile as sf
from denoisers.demucs import DemucsStreamer
from denoisers import pretrained
model = pretrained.demucs()
streamer = DemucsStreamer(model)
for f in files:
    src = Path(f); dst = out_dir / src.name
    if dst.exists(): continue
    data, rate = sf.read(str(src), dtype="float32")
    if getattr(data, "ndim", 1) > 1: data = data.mean(axis=1)
    wav = torch.from_numpy(data)[None]
    with torch.no_grad():
        enhanced = model(wav)[0]
    sf.write(str(dst), enhanced.cpu().numpy(), rate)
    print(".", end="", flush=True)
print(" done")
""",
}


def decode_filter(filter_name: str, denoised_dir: Path, exp: Path) -> Path:
    """Decode the denoised set with the champion config (temperature 0.2, best_of 10, P5)."""
    out = exp / f"decodes-stage-c5-{filter_name}.jsonl"
    if out.exists():
        print(f"[{filter_name}] decodes exist", flush=True)
        return out
    config_name = f"w-bo-t20-n10-v1-dn-{filter_name}"
    config_file = exp / f"c5-config-{filter_name}.json"
    config_file.write_text(
        json.dumps(
            {
                config_name: {
                    "temperature": 0.2,
                    "condition_on_previous_text": False,
                    "best_of": 10,
                    "initial_prompt": DEV_PROMPT_P5,
                }
            }
        ),
        encoding="utf-8",
    )
    lst = exp / f"c5-files-{filter_name}.txt"
    lst.write_text("\n".join(str(p) for p in sorted(denoised_dir.glob("rec-*.wav"))) + "\n", encoding="utf-8")
    log = exp / f"c5-decode-{filter_name}.log"
    cmd = [
        str(VENV_ROOT / "venv-whisper/bin/python"),
        str(WORKER),
        "--engine",
        "whisper",
        "--configs",
        config_name,
        "--config-file",
        str(config_file),
        "--list",
        str(lst),
        "--out",
        str(out),
    ]
    print(f"[{filter_name}] decoding → {out.name}", flush=True)
    with log.open("w") as log_handle:
        proc = subprocess.run(cmd, stdout=log_handle, stderr=subprocess.STDOUT)
    if proc.returncode != 0 or not out.exists():
        raise RuntimeError(f"decode {filter_name} failed, see {log}")
    return out


DEV_PROMPT_P5 = (
    "Диктовка по разработке: Swift, Python, Xcode, Git, API, модель, промпт, "
    "транскрипция, репозиторий, коммит, ветка, тесты, сервер."
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--filters", default=",".join(FILTERS))
    parser.add_argument("--skip-decode", action="store_true", help="only produce denoised wav")
    parser.add_argument("--only-denoise", action="store_true")
    args = parser.parse_args()

    exp = GT / "experiments"
    out_root = exp / "denoised"
    out_root.mkdir(parents=True, exist_ok=True)

    files = build_file_list()
    print(f"measurement set: {len(files)} files", flush=True)

    ensure_denoise_venv()
    installs = {
        "dfn3": ["DeepFilterNet", "soundfile", "numpy"],
        "rnnoise": ["rnnoise", "soundfile", "numpy"],
        "noisereduce": ["noisereduce", "soundfile", "numpy"],
        "fbdenoiser": ["denoisers", "soundfile", "numpy", "torch"],
    }
    for f in args.filters.split(","):
        if f in installs:
            print(f"installing deps for {f} …", flush=True)
            pip_install(*installs[f])

    results = {}
    for f in [x for x in args.filters.split(",") if x]:
        try:
            denoised_dir = denoise_all(f, files, out_root)
            if args.skip_decode or args.only_denoise:
                results[f] = {"status": "denoised", "dir": str(denoised_dir)}
                continue
            decodes = decode_filter(f, denoised_dir, exp)
            results[f] = {"status": "decoded", "decodes": str(decodes)}
        except Exception as error:  # noqa: BLE001
            results[f] = {"status": "failed", "error": str(error)[:500]}
            print(f"[{f}] FAILED: {error}", flush=True)
    print(json.dumps(results, ensure_ascii=False, indent=2), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

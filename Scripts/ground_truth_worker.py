#!/usr/bin/env python3
"""Decode one list of recordings with one engine configuration.

Runs INSIDE an engine venv (venv-whisper, venv-fasterwhisper or venv-gigaam),
because their Python dependencies conflict and cannot share a process. The model is loaded once and
reused for the whole list — that is the entire reason this is a batch worker and
not a per-file invocation, since a Whisper load costs more than a short decode.

Emits one JSON object per line on stdout; the orchestrator owns the result file.
Never raises on a bad recording: a failed decode is a result with an error, so
one unreadable file cannot end an overnight run.

Usage:
    <venv>/bin/python ground_truth_worker.py --engine whisper \
        --configs w-greedy,w-offset --list files.txt
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

# Whisper is asked the same question five different ways. There is no beam
# search to reach for — mlx_whisper raises NotImplementedError for beam_size —
# so the diversity has to come from temperature, conditioning and prompting:
#
#   w-greedy    temperature 0, no cross-window conditioning. Deterministic, and
#               the strongest single decode this backend can produce.
#   w-fallback  every mlx default, i.e. exactly what the app ships today. Kept
#               as a voter so the shipping config is judged, never the judge.
#   w-prompt    greedy, primed with the vocabulary actually dictated here.
#               Changes terminology and spelling, not the acoustics.
#   w-sample    the only non-deterministic member: best_of N sampled decodes,
#               ranked by average logprob. This is where "run the file more
#               times" genuinely buys something — repeating a temperature-0
#               decode returns byte-identical text and buys nothing at all.
DEV_PROMPT = (
    "Диктовка по разработке: Swift, Python, Xcode, Git, API, модель, промпт, "
    "транскрипция, репозиторий, коммит, ветка, тесты, сервер."
)
WHISPER_OPTIONS: dict[str, dict] = {
    "w-greedy": {"temperature": 0.0, "condition_on_previous_text": False},
    "w-fallback": {},
    "w-prompt": {"temperature": 0.0, "condition_on_previous_text": False,
                 "initial_prompt": DEV_PROMPT},
    "w-sample": {"temperature": 0.4, "condition_on_previous_text": False},
    # Same decode as w-greedy, but the audio is padded so Whisper's 30 s window
    # boundaries land somewhere else. Its errors cluster at those seams, so a
    # shifted grid is a genuinely different reading of the same audio and costs
    # nothing but time. Pointless on short files, which are a single window.
    "w-offset": {"temperature": 0.0, "condition_on_previous_text": False},
}
OFFSET_SECONDS = 15.0
OFFSET_MIN_SECONDS = 30.0


def emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def load_audio(path: str, offset: float = 0.0):
    import numpy as np
    import soundfile as sf

    data, rate = sf.read(path, dtype="float32")
    if getattr(data, "ndim", 1) > 1:
        data = data.mean(axis=1)
    if rate != 16000:
        count = int(round(len(data) * 16000 / rate))
        data = np.interp(np.linspace(0, len(data), count, endpoint=False),
                         np.arange(len(data)), data).astype(np.float32)
    if offset:
        data = np.concatenate([np.zeros(int(offset * 16000), dtype="float32"), data])
    return np.ascontiguousarray(data)


def whisper_decoder(config: str, repository: str, best_of: int):
    import mlx_whisper

    options = dict(WHISPER_OPTIONS[config])
    if config == "w-sample":
        options["best_of"] = best_of
    options.update(path_or_hf_repo=repository, language="ru")
    # Word times come from the tier-one decode only. They are what lets the
    # review panel play the four seconds under dispute instead of the whole
    # recording, and asking every config for them would just cost time.
    options["word_timestamps"] = config == "w-greedy"

    def decode(path: str) -> tuple[str, dict]:
        offset = OFFSET_SECONDS if config == "w-offset" else 0.0
        audio = load_audio(path, offset)
        if config == "w-offset" and len(audio) / 16000 - offset < OFFSET_MIN_SECONDS:
            raise TooShortForOffset("single 30 s window; a shifted grid decodes the same thing")
        result = mlx_whisper.transcribe(audio, **options)
        segments = result.get("segments") or []
        # The MINIMUM no_speech_prob across segments, not the mean: the question
        # is whether any part of the recording contains speech, and one confident
        # segment is enough to answer yes. Measured on this corpus, a
        # hallucinated "Спасибо." over silence reports 0.851 while real speech
        # reports 0.020 — Whisper knows, it just is not asked.
        metrics = {
            "no_speech": min((s.get("no_speech_prob", 1.0) for s in segments), default=1.0),
            "avg_logprob": min((s.get("avg_logprob", 0.0) for s in segments), default=0.0),
            "compression": max((s.get("compression_ratio", 0.0) for s in segments), default=0.0),
        }
        if options["word_timestamps"]:
            metrics["words"] = [[w.get("word", "").strip(), round(w.get("start", 0.0), 2),
                                 round(w.get("end", 0.0), 2)]
                                for s in segments for w in (s.get("words") or [])]
        return (result.get("text") or "").strip(), metrics

    # One warm call is not needed: mlx caches the model on first transcribe and
    # the orchestrator already treats the first file's timing as unrepresentative.
    return decode


class TooShortForOffset(Exception):
    """Not a failure: the shifted-grid pass has nothing to add on a file that
    fits one window, so it is skipped rather than recorded as an error."""


def faster_whisper_decoder(model_size: str, root: str):
    """CTranslate2 Whisper. Same weights as the mlx passes, so NOT an
    independent architecture — but it is the only backend here that implements
    beam search, which mlx_whisper refuses outright."""
    from faster_whisper import WhisperModel

    model = WhisperModel(model_size, device="cpu", compute_type="int8", download_root=root or None)

    def decode(path: str) -> tuple[str, dict]:
        segments, _ = model.transcribe(path, language="ru", beam_size=5, temperature=0.0,
                                       condition_on_previous_text=False)
        collected = list(segments)
        text = " ".join(s.text.strip() for s in collected).strip()
        return text, {
            "no_speech": min((s.no_speech_prob for s in collected), default=1.0),
            "avg_logprob": min((s.avg_logprob for s in collected), default=0.0),
        }

    return decode


def gigaam_decoder(model_name: str, root: str):
    import gigaam

    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Soma"))
    from voice_asr_engines import transcribe_gigaam   # the app's own windowing

    model = gigaam.load_model(model_name, device="cpu", download_root=root or None)

    def decode(path: str) -> tuple[str, dict]:
        return transcribe_gigaam(path, model), {}

    return decode


def peak_db(path: str) -> float:
    """Loudest sample in the file, in dBFS. Model-independent corroboration for
    a silence call — an engine can hallucinate, a waveform cannot."""
    import numpy as np
    import soundfile as sf

    data, _ = sf.read(path, dtype="float32")
    if getattr(data, "ndim", 1) > 1:
        data = data.mean(axis=1)
    return round(float(20 * np.log10(max(abs(data).max() if len(data) else 0.0, 1e-9))), 1)


# Which checkpoint each GigaAM config loads. Both share an encoder but decode
# through different heads, so they agree far more often with each other than
# either does with Whisper — they are one-and-a-bit votes, not two.
GIGAAM_MODELS = {"gigaam": "rnnt", "gigaam-ctc": "ctc"}


def build_decoder(args, config: str) -> object:
    if args.engine == "whisper":
        return whisper_decoder(config, args.repository, args.best_of)
    if args.engine == "fasterwhisper":
        return faster_whisper_decoder(args.faster_model, args.faster_root)
    return gigaam_decoder(GIGAAM_MODELS.get(config, args.gigaam_model), args.gigaam_root)


def run_config(args, config: str, paths: list[str]) -> None:
    started = time.perf_counter()
    try:
        decode = build_decoder(args, config)
    except Exception as error:                                    # noqa: BLE001
        emit({"event": "fatal", "config": config, "error": f"{type(error).__name__}: {error}"})
        return
    emit({"event": "loaded", "config": config, "seconds": round(time.perf_counter() - started, 2)})

    for path in paths:
        began = time.perf_counter()
        metrics: dict = {}
        try:
            text, error = None, None
            text, metrics = decode(path)
            metrics["peak_db"] = peak_db(path)
        except TooShortForOffset as skipped:
            emit({"event": "skip", "file": Path(path).name, "config": config, "reason": str(skipped)})
            continue
        except Exception as failure:                              # noqa: BLE001
            text, error = None, f"{type(failure).__name__}: {failure}"
        emit({"event": "decode", "file": Path(path).name, "config": config, "text": text,
              "error": error, "seconds": round(time.perf_counter() - began, 2), **metrics})


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", required=True, choices=["whisper", "gigaam", "fasterwhisper"])
    # Several configs in one process on purpose: they share the loaded model, and
    # a Whisper load costs more than a short decode does.
    parser.add_argument("--configs", default="gigaam", help="comma-separated config names")
    parser.add_argument("--list", required=True, type=Path, help="file with one audio path per line")
    parser.add_argument("--repository", default="mlx-community/whisper-large-v3-mlx")
    parser.add_argument("--best-of", type=int, default=5, help="sampled decodes per window for w-sample")
    parser.add_argument("--gigaam-model", default="rnnt")
    parser.add_argument("--gigaam-root", default="")
    parser.add_argument("--faster-model", default="large-v3")
    parser.add_argument("--faster-root", default="")
    args = parser.parse_args(argv)

    paths = [line.strip() for line in args.list.read_text(encoding="utf-8").splitlines() if line.strip()]
    for config in [name for name in args.configs.split(",") if name]:
        run_config(args, config, paths)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

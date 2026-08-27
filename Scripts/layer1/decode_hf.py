#!/usr/bin/env python3
"""Parakeet / Qwen3 / wav2vec2 / MMS / Vosk / faster-whisper decoders for Layer 1.

Usage: decode_hf.py <audio> <kind>
kinds: parakeet, qwen3, wav2vec2, mms, vosk
Runs inside venv-asr-eval (torch/transformers/vosk all installed there).
"""
import json
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")


def load16(path):
    import torchaudio

    audio, sr = torchaudio.load(path)
    if sr != 16000:
        audio = torchaudio.functional.resample(audio, sr, 16000)
    return audio.squeeze(0).numpy()


def decode_parakeet(path):
    import torch
    from transformers import AutoProcessor, ParakeetForTDT

    proc = AutoProcessor.from_pretrained("nvidia/parakeet-tdt-0.6b-v3")
    model = ParakeetForTDT.from_pretrained("nvidia/parakeet-tdt-0.6b-v3").eval()
    inputs = proc(load16(path), sampling_rate=16000, return_tensors="pt")
    with torch.no_grad():
        generated = model.generate(**inputs)
    sequences = getattr(generated, "sequences", None)
    if sequences is None:
        sequences = generated[0] if isinstance(generated, (list, tuple)) else generated
    text = proc.tokenizer.batch_decode(sequences, skip_special_tokens=True)[0]
    return text, [], "parakeet-tdt-0.6b-v3"


def decode_qwen3(path):
    import torch
    from transformers import AutoProcessor, Qwen3ASRForConditionalGeneration

    audio = load16(path)
    proc = AutoProcessor.from_pretrained("Qwen/Qwen3-ASR-1.7B-hf")
    model = Qwen3ASRForConditionalGeneration.from_pretrained(
        "Qwen/Qwen3-ASR-1.7B-hf", dtype=torch.float32).eval()
    conv = [{"role": "user", "content": [
        {"type": "audio", "audio": audio},
        {"type": "text", "text": "Transcribe this audio."}]}]
    text = proc.apply_chat_template(conv, add_generation_prompt=True, tokenize=False)
    inputs = proc(text=[text], audio=[audio], sampling_rate=16000,
                  return_tensors="pt", padding=True)
    with torch.no_grad():
        ids = model.generate(**inputs, max_new_tokens=768)
    raw = proc.tokenizer.batch_decode(ids, skip_special_tokens=True)[0]
    import re

    return re.sub(r"^.*?<asr_text>", "", raw, flags=re.S).strip(), [], "qwen3-asr-1.7b"


def decode_wav2vec2(path):
    import torch
    from transformers import Wav2Vec2ForCTC, Wav2Vec2Processor

    repo = "jonatasgrosman/wav2vec2-large-xlsr-53-russian"
    proc = Wav2Vec2Processor.from_pretrained(repo)
    model = Wav2Vec2ForCTC.from_pretrained(repo)
    inputs = proc(load16(path), sampling_rate=16000, return_tensors="pt", padding=True)
    with torch.no_grad():
        logits = model(inputs.input_values).logits
    return proc.batch_decode(torch.argmax(logits, dim=-1))[0], [], "wav2vec2-xlsr-53-ru"


def decode_mms(path):
    import torch
    from transformers import Wav2Vec2ForCTC, Wav2Vec2Processor

    proc = Wav2Vec2Processor.from_pretrained("facebook/mms-1b-all", target_lang="rus")
    model = Wav2Vec2ForCTC.from_pretrained("facebook/mms-1b-all", target_lang="rus",
                                           ignore_mismatched_sizes=True)
    inputs = proc(load16(path), sampling_rate=16000, return_tensors="pt", padding=True)
    with torch.no_grad():
        logits = model(inputs.input_values).logits
    return proc.batch_decode(torch.argmax(logits, dim=-1))[0], [], "mms-1b-rus"


def decode_vosk(path):
    import wave

    from vosk import KaldiRecognizer, Model

    model = Model(str(Path.home() / "Daliys/AIModels/vosk/vosk-model-small-ru-0.22"))
    recognizer = KaldiRecognizer(model, 16000)
    with wave.open(path) as handle:
        while True:
            chunk = handle.readframes(4000)
            if not chunk:
                break
            recognizer.AcceptWaveform(chunk)
    final = json.loads(recognizer.FinalResult())
    words = [{"word": w.get("word", ""), "start": round(w.get("start", 0.0), 2),
              "end": round(w.get("end", 0.0), 2)} for w in final.get("result", [])]
    return final.get("text", ""), words, "vosk-small-ru-0.22"


DECODERS = {"parakeet": decode_parakeet, "qwen3": decode_qwen3,
            "wav2vec2": decode_wav2vec2, "mms": decode_mms, "vosk": decode_vosk}


def main() -> int:
    path, kind = sys.argv[1], sys.argv[2]
    try:
        text, words, version = DECODERS[kind](path)
        print(json.dumps({"text": (text or "").strip(), "words": words,
                          "version": version}, ensure_ascii=False))
        return 0
    except Exception as error:  # noqa: BLE001
        print(json.dumps({"text": "", "words": [], "version": kind,
                          "error": f"{type(error).__name__}: {error}"[:300]}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

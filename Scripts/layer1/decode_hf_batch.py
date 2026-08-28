#!/usr/bin/env python3
"""Run the HF ASR voices over a Layer-1 manifest with one model load."""

from __future__ import annotations

import json
import re
import sys
import warnings
import wave
from pathlib import Path

warnings.filterwarnings("ignore")


def load16(path):
    import torchaudio

    audio, sr = torchaudio.load(path)
    if audio.shape[0] > 1:
        audio = audio.mean(dim=0, keepdim=True)
    if sr != 16000:
        audio = torchaudio.functional.resample(audio, sr, 16000)
    return audio.squeeze(0).numpy()


def run(kind, rows):
    import torch

    if kind == "parakeet":
        from transformers import AutoProcessor, ParakeetForTDT

        proc = AutoProcessor.from_pretrained("nvidia/parakeet-tdt-0.6b-v3")
        model = ParakeetForTDT.from_pretrained("nvidia/parakeet-tdt-0.6b-v3").eval()
        for row in rows:
            inputs = proc(load16(row["audio"]), sampling_rate=16000, return_tensors="pt")
            with torch.no_grad():
                generated = model.generate(**inputs)
            sequences = getattr(generated, "sequences", None)
            if sequences is None:
                sequences = generated
            text = proc.tokenizer.batch_decode(sequences, skip_special_tokens=True)[0]
            yield row, text, [], "parakeet-tdt-0.6b-v3"
    elif kind == "qwen3":
        from transformers import AutoProcessor, Qwen3ASRForConditionalGeneration

        proc = AutoProcessor.from_pretrained("Qwen/Qwen3-ASR-1.7B-hf")
        model = Qwen3ASRForConditionalGeneration.from_pretrained("Qwen/Qwen3-ASR-1.7B-hf", dtype=torch.float32).eval()
        for row in rows:
            audio = load16(row["audio"])
            conv = [
                {
                    "role": "user",
                    "content": [{"type": "audio", "audio": audio}, {"type": "text", "text": "Transcribe this audio."}],
                }
            ]
            prompt = proc.apply_chat_template(conv, add_generation_prompt=True, tokenize=False)
            inputs = proc(text=[prompt], audio=[audio], sampling_rate=16000, return_tensors="pt", padding=True)
            with torch.no_grad():
                ids = model.generate(**inputs, max_new_tokens=768)
            raw = proc.tokenizer.batch_decode(ids, skip_special_tokens=True)[0]
            yield row, re.sub(r"^.*?<asr_text>", "", raw, flags=re.S).strip(), [], "qwen3-asr-1.7b"
    elif kind in ("wav2vec2", "mms"):
        from transformers import Wav2Vec2ForCTC, Wav2Vec2Processor

        repo = "jonatasgrosman/wav2vec2-large-xlsr-53-russian" if kind == "wav2vec2" else "facebook/mms-1b-all"
        kwargs = {"target_lang": "rus"} if kind == "mms" else {}
        proc = Wav2Vec2Processor.from_pretrained(repo, **kwargs)
        model = Wav2Vec2ForCTC.from_pretrained(
            repo, **kwargs, **({"ignore_mismatched_sizes": True} if kind == "mms" else {})
        )
        for row in rows:
            inputs = proc(load16(row["audio"]), sampling_rate=16000, return_tensors="pt", padding=True)
            with torch.no_grad():
                logits = model(inputs.input_values).logits
            yield row, proc.batch_decode(torch.argmax(logits, dim=-1))[0], [], f"{kind}-ru"
    elif kind == "vosk":
        import numpy as np
        from vosk import KaldiRecognizer, Model

        model = Model(str(Path.home() / "Daliys/AIModels/vosk/vosk-model-small-ru-0.22"))
        for row in rows:
            rec = KaldiRecognizer(model, 16000)
            rec.SetWords(True)
            audio = load16(row["audio"])
            pcm = (np.clip(audio, -1.0, 1.0) * 32767.0).astype(np.int16).tobytes()
            chunk_size = 8000
            for i in range(0, len(pcm), chunk_size):
                rec.AcceptWaveform(pcm[i : i + chunk_size])
            final = json.loads(rec.FinalResult())
            words = [
                {"word": w.get("word", ""), "start": round(w.get("start", 0.0), 2), "end": round(w.get("end", 0.0), 2)}
                for w in final.get("result", [])
            ]
            yield row, final.get("text", ""), words, "vosk-small-ru-0.22"
    else:
        raise ValueError(f"unknown kind: {kind}")


def main() -> int:
    manifest, kind = Path(sys.argv[1]), sys.argv[2]
    rows = [json.loads(line) for line in manifest.read_text().splitlines() if line.strip()]
    for row, text, words, version in run(kind, rows):
        print(
            json.dumps(
                {
                    "id": row["id"],
                    "file": row["file"],
                    "text": (text or "").strip(),
                    "words": words,
                    "version": version,
                },
                ensure_ascii=False,
            ),
            flush=True,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

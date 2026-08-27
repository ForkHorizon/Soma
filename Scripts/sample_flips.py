#!/usr/bin/env python3
"""Generate a stratified sample of 30 flips for human audio evaluation (Stage 4.3)."""

import argparse
import json
import random
from pathlib import Path

DEFAULT_INPUT = Path.home() / "Library/Application Support/Soma/GroundTruth/experiments/flips-final-candidate.jsonl"
DEFAULT_AUDIO_DIR = Path.home() / "Library/Application Support/Soma/VoiceRecordings"


def sample_flips(input_file: Path, audio_dir: Path, seed: int = 42) -> list[dict]:
    random.seed(seed)
    categories = {"term": [], "filler": [], "phrasing": []}

    with open(input_file, "r", encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            item = json.loads(line)
            cat = item.get("category")
            if cat in categories:
                categories[cat].append(item)

    # Stratified sampling: 10 term, 10 filler, 10 phrasing
    sampled = []
    for cat, items in categories.items():
        n = min(10, len(items))
        cat_samples = random.sample(items, n)
        for item in cat_samples:
            item_copy = dict(item)
            wav_path = audio_dir / item_copy["file"]
            item_copy["audio_exists"] = wav_path.exists()
            item_copy["audio_path"] = str(wav_path)
            sampled.append(item_copy)

    # Shuffle the combined 30 items deterministically
    random.shuffle(sampled)
    return sampled


def generate_markdown(sampled: list[dict]) -> str:
    lines = []
    lines.append("# Выборка флипов для прослушивания (Этап 4.3)")
    lines.append("")
    lines.append(
        "Ниже представлены 30 случайных фрагментов (10 терминов, 10 филлеров, 10 формулировок), в которых **Base (`w-greedy`)** и **Candidate (`w-final-candidate`)** выдали разный результат."
    )
    lines.append("")
    lines.append("## Инструкция по оценке")
    lines.append(
        "1. Для каждого пункта найдите и послушайте аудиофайл (путь указан в строке). Можно открыть через Finder, проиграть `afplay <путь>` в терминале или встроенным плеером."
    )
    lines.append("2. Прочитайте контекст и сравните два варианта:")
    lines.append("   - **A (Base)**: старая дефолтная модель `w-greedy`")
    lines.append(
        "   - **B (Candidate)**: новый кандидат `w-final-candidate` (`temperature=0.2, best_of=10, initial_prompt=P5`)"
    )
    lines.append("3. Выберите, какой вариант вернее/точнее передаёт сказанное в аудио:")
    lines.append("   - **A** — выиграла База")
    lines.append("   - **B** — выиграл Кандидат")
    lines.append("   - **=** — оба одинаково хороши / нейтрально")
    lines.append(
        "4. Напишите результаты мне прямо в ответ (например, списком `1: B, 2: B, 3: A, 4: =...` или итоговым счётом `B: 20, A: 5, =: 5`)."
    )
    lines.append("")
    lines.append("---")
    lines.append("")

    for idx, item in enumerate(sampled, 1):
        file_name = item["file"]
        audio_path = item["audio_path"]
        cat = item["category"].upper()
        ctx_before = item["context_before"]
        ctx_after = item["context_after"]
        base = item["base"] if item["base"] else "∅ (пусто)"
        cand = item["candidate"] if item["candidate"] else "∅ (пусто)"

        lines.append(f"### № {idx}. [{cat}] `{file_name}`")
        lines.append(f"- **Аудио**: `{audio_path}`")
        lines.append(f"- **Контекст**: `... {ctx_before}` **[ A vs B ]** `{ctx_after} ...`")
        lines.append(f"- **A (Base)**: `{base}`")
        lines.append(f"- **B (Candidate)**: `{cand}`")
        lines.append("- **Вердикт**: [ ] **A** | [ ] **B** | [ ] **=**")
        lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--audio-dir", type=Path, default=DEFAULT_AUDIO_DIR)
    parser.add_argument("--out-json", type=Path)
    parser.add_argument("--out-md", type=Path)
    args = parser.parse_args()

    sampled = sample_flips(args.input, args.audio_dir)
    md_content = generate_markdown(sampled)

    if args.out_md:
        args.out_md.write_text(md_content, encoding="utf-8")
        print(f"Wrote markdown to {args.out_md}")
    if args.out_json:
        args.out_json.write_text(json.dumps(sampled, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"Wrote json to {args.out_json}")


if __name__ == "__main__":
    main()

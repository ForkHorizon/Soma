#!/usr/bin/env python3
"""Stage 5.1: GigaAM as a hallucination detector (silence veto post-filter)."""
import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from asr_eval import load_decodes, score, DEFAULT_ROOT, read_jsonl
from ground_truth_consensus import repeats_itself
from ground_truth_text import normalize

BOILERPLATE = re.compile(
    r"(?:субтитры|продолжение следует|продолжаю с сайта|скачиваю сайт|добавляю github|слушаю github)",
    re.IGNORECASE
)

def is_gigaam_silent(cfgs: dict[str, str]) -> bool:
    giga1 = cfgs.get("gigaam", "").strip()
    giga2 = cfgs.get("gigaam-ctc", "").strip()
    return not giga1 and not giga2

def apply_gigaam_veto(decodes: dict[str, dict[str, str]], no_speech_map: dict[tuple[str, str], float],
                       candidate_cfg: str, mode: str) -> dict[str, dict[str, str]]:
    filtered_decodes = {}
    for file, cfgs in decodes.items():
        filtered_decodes[file] = dict(cfgs)
        cand_text = cfgs.get(candidate_cfg)
        if cand_text is None:
            continue

        giga_silent = is_gigaam_silent(cfgs)
        ns_prob = no_speech_map.get((file, candidate_cfg), 0.0)

        should_veto = False
        if giga_silent:
            if mode == "strict_consensus":
                # Consensus rule: GigaAM silent AND (no_speech >= 0.8 OR repeats OR boilerplate)
                if ns_prob >= 0.8 or repeats_itself(normalize(cand_text)) or BOILERPLATE.search(cand_text):
                    should_veto = True
            elif mode == "gigaam_hallucination_veto":
                # GigaAM silent AND (no_speech >= 0.4 OR repeats OR boilerplate)
                if ns_prob >= 0.4 or repeats_itself(normalize(cand_text)) or BOILERPLATE.search(cand_text):
                    should_veto = True
            elif mode == "pure_gigaam_veto":
                # GigaAM silent -> veto everything
                should_veto = True

        if should_veto:
            new_cfg_name = f"{candidate_cfg}-{mode}"
            filtered_decodes[file][new_cfg_name] = ""
        else:
            new_cfg_name = f"{candidate_cfg}-{mode}"
            filtered_decodes[file][new_cfg_name] = cand_text

    return filtered_decodes

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--candidate-config", default="w-bo-t20-n10-v1")
    parser.add_argument("--candidate-file", type=Path, default=DEFAULT_ROOT / "experiments/decodes-stage3-bo10.jsonl")
    args = parser.parse_args()

    baseline_file = args.root.parent / "Scripts/asr_baseline.json" if (args.root.parent / "Scripts/asr_baseline.json").exists() else Path("Scripts/asr_baseline.json")
    decodes_main = load_decodes([args.root / "decodes.jsonl", args.candidate_file])

    rows_main = read_jsonl(args.root / "decodes.jsonl") + read_jsonl(args.candidate_file)
    no_speech_map = {}
    for r in rows_main:
        f, cfg = r.get("file"), r.get("config")
        if f and cfg and "no_speech" in r:
            no_speech_map[(f, cfg)] = r["no_speech"]

    for mode in ["strict_consensus", "gigaam_hallucination_veto", "pure_gigaam_veto"]:
        filtered = apply_gigaam_veto(decodes_main, no_speech_map, args.candidate_config, mode)
        cfg_name = f"{args.candidate_config}-{mode}"

        # Save filtered decodes to experiment jsonl
        out_rows = []
        for file, cfgs in filtered.items():
            if cfg_name in cfgs:
                out_rows.append({"file": file, "config": cfg_name, "text": cfgs[cfg_name]})

        out_file = args.root / f"experiments/decodes-stage5-veto-{mode}.jsonl"
        out_file.parent.mkdir(parents=True, exist_ok=True)
        out_file.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in out_rows) + "\n", encoding="utf-8")
        print(f"Saved {len(out_rows)} decodes to {out_file.name}")

if __name__ == "__main__":
    main()

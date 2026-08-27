#!/usr/bin/env python3
"""Stage 3: generate the decode-parameter grids (3.1 best_of, 3.2 filter
thresholds) as a --config-file JSON, the same mechanism stage 2 used.

Every stage-3 run uses the accepted stage-2 prompt via --prompt-config. An
omitted prompt still cleanly generates a P0 control grid.

Verified against the installed mlx_whisper before writing this (see
ASR_TUNING_PLAN.md stage 3 notes): best_of flows through mlx_whisper's
**decode_options, not a named parameter, exactly like the existing w-sample
config already relies on. And the plan's stated no_speech_threshold default
of 0.5 is wrong -- mlx_whisper.transcribe's actual default is 0.6. logprob
(-1.0) and compression_ratio (2.4) defaults are confirmed correct as stated.

    ./generate_stage3_configs.py --out experiments/stage3_configs.json
    ./generate_stage3_configs.py --out experiments/stage3_configs.json \
        --prompt-config w-p-p5-v1   # bake in a chosen stage-2 winner
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

DEFAULT_STAGE2_PROMPTS = Path(__file__).resolve().parent / "experiments" / "stage2_prompts.json"

# 3.1: {t=0.2, t=0.4} x {best_of 3, 5, 10}. temperature is a single float here,
# not mlx_whisper's default fallback tuple -- matching how w-sample already
# pins one value instead of the ladder.
BEST_OF_GRID = [(temperature, best_of) for temperature in (0.2, 0.4) for best_of in (3, 5, 10)]

# 3.2: one non-default value away from the REAL default at a time, not a full
# cross product -- the plan's own examples read as independent single-factor
# sweeps, and a full 3x2x2 grid would blow well past "one run a night".
# no_speech_threshold's two test points (0.4, 0.5) are both below the true
# 0.6 default, matching the plan's original two candidate values even though
# its stated default was wrong.
THRESHOLD_GRID = [
    ("no_speech_threshold", 0.4),
    ("no_speech_threshold", 0.5),
    ("logprob_threshold", -0.7),
    ("compression_ratio_threshold", 2.0),
]

# 3.2b: no_speech only becomes observable when paired with the tighter
# logprob threshold. These are the one permitted follow-up to the 3.2 sweep.
JOINT_THRESHOLD_GRID = [
    ("w-thr2-no70-lp07-v1", {"no_speech_threshold": 0.7, "logprob_threshold": -0.7}),
    ("w-thr2-no85-lp07-v1", {"no_speech_threshold": 0.85, "logprob_threshold": -0.7}),
]


def load_prompt(name: str | None, prompts_path: Path) -> str | None:
    if not name:
        return None
    prompts = json.loads(prompts_path.read_text(encoding="utf-8"))
    options = prompts.get(name)
    if options is None:
        raise ValueError(f"'{name}' not found in {prompts_path} (have: {sorted(prompts)})")
    return options.get("initial_prompt")


def build(prompt: str | None) -> dict[str, dict]:
    variants: dict[str, dict] = {}
    for temperature, best_of in BEST_OF_GRID:
        name = f"w-bo-t{int(temperature * 100):02d}-n{best_of}-v1"
        options = {"temperature": temperature, "condition_on_previous_text": False, "best_of": best_of}
        if prompt:
            options["initial_prompt"] = prompt
        variants[name] = options

    # Threshold names spell out the value (e.g. nospeech04) rather than just
    # the parameter, since two of the four share no_speech_threshold and a
    # bare "w-thr-nospeech-v1" x2 would collide (hygiene rule 2).
    for param, value in THRESHOLD_GRID:
        short = param.split("_")[0]
        tag = f"{value}".replace(".", "").replace("-", "neg")
        name = f"w-thr-{short}{tag}-v1"
        options = {"temperature": 0.0, "condition_on_previous_text": False, param: value}
        if prompt:
            options["initial_prompt"] = prompt
        variants[name] = options

    for name, options in JOINT_THRESHOLD_GRID:
        options = {"temperature": 0.0, "condition_on_previous_text": False, **options}
        if prompt:
            options["initial_prompt"] = prompt
        variants[name] = options

    # 3.4: turbo run, decoded with --repository pointed at the turbo model.
    # temperature=0.2, best_of=10 -- w-bo-t20-n10-v1 is the only 3.1 config
    # that actually beat baseline WER (0.0256 vs 0.0286) and by far the
    # biggest latin gain (43.2 vs the prompt-only 28.6), scored after the
    # 2026-08-07 best_of=3/5/10 runs completed. condition_on_previous_text
    # stays False, matching every other stage-3 config.
    turbo_options = {"temperature": 0.2, "condition_on_previous_text": False, "best_of": 10}
    if prompt:
        turbo_options["initial_prompt"] = prompt
    variants["w-turbo-v1"] = turbo_options
    return variants


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument(
        "--prompt-config",
        help="a config name from --prompts-file, e.g. w-p-p5-v1; omit to run the grid with no prompt (P0)",
    )
    parser.add_argument(
        "--prompts-file",
        type=Path,
        default=DEFAULT_STAGE2_PROMPTS,
        help="stage 2's --config-file JSON to pull --prompt-config's initial_prompt from",
    )
    args = parser.parse_args()

    prompt = load_prompt(args.prompt_config, args.prompts_file)
    variants = build(prompt)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(variants, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    for name, options in variants.items():
        print(f"{name}: {options}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

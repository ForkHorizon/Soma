#!/bin/sh
# 3.2b joint threshold grid, then 3.4 turbo -- run sequentially, same MLX venv.
set -e
cd /Users/daliys/Daliys/Swift/Soma
export HF_HOME=/Users/daliys/Daliys/AI_Test_PlayGround/asr-models/hf
export PYTORCH_ENABLE_MPS_FALLBACK=1
export PYTHONUNBUFFERED=1
GT="$HOME/Library/Application Support/Soma/GroundTruth/archives/pre-structure-v1/root"
VENV=/Users/daliys/Daliys/AI_Test_PlayGround/asr-engines/venv-whisper/bin/python

"$VENV" Scripts/ground_truth_worker.py --engine whisper \
  --configs w-thr2-no70-lp07-v1,w-thr2-no85-lp07-v1 \
  --list Scripts/experiments/stage2_corpus.txt \
  --config-file Scripts/experiments/stage3_configs.json \
  --out "$GT/experiments/decodes-stage3-thresholds2.jsonl"

"$VENV" Scripts/ground_truth_worker.py --engine whisper \
  --configs w-turbo-v1 \
  --repository mlx-community/whisper-large-v3-turbo \
  --list Scripts/experiments/stage2_corpus.txt \
  --config-file Scripts/experiments/stage3_configs.json \
  --out "$GT/experiments/decodes-stage3-turbo.jsonl"

# SOMA.md

## Purpose

Soma is a personal local-first workbench for testing language models, plus a per-project tool/MCP control panel. The daily product loop:

1. Speak or type a task in Russian (Voice to Text / Rus to Prompt).
2. Soma normalizes it to a clean English prompt.
3. Run it across local (Ollama) and paid (DeepSeek, Gemini, OpenAI) models — Queue / Tests.
4. Compare output, latency, and token cost — Model Stats / Token Calculator.
5. Manage the tools wired into each project (Graphify, Ponytail, projectmem, MCP configs) — Extensions / System Status.

The near-term goal is comfort and daily use, not more features.

Legacy: the evidence-compiler / packet pipeline (`scout_pipeline_module/`, `gateway/`, `soma_mcp_server.py`) is retained only as the backend for the System Status MCP control panel. The Prepare-Packet, Packets, Projects, Project Health, Diagnostics, and Scout screens were removed in the model-bench cleanup (branch `cleanup/model-bench-pivot`).

## Important Paths

- `Soma/Views/RusToPromptView*.swift`: Russian → English prompt workflow.
- `Soma/Views/TestsView*.swift`: run prompt cases across models; `.queue` and `.stats` modes back the Queue and Model Stats routes.
- `Soma/Views/VoiceToTextView.swift`: local speech-to-text (engine picker: Whisper large-v3 / GigaAM v2).
- `Soma/Views/SystemStatusView.swift`: MCP-config control panel (install/verify Codex/Gemini/Hermes, start server, smoke, benchmark reports).
- `Soma/Views/ToolVersionsView.swift`: Extensions panel — check/update globally installed tools (Graphify, Ponytail, projectmem).
- `Soma/ViewModels/RusToPromptQueueManager*.swift`: prompt run queue and model execution.
- `Soma/soma_language_optimizer*.py`: prompt normalization backend.
- ASR backend lives outside the repo at `AI_Test_PlayGround/asr-engines/asr_server.py` (warm multi-engine server; per-engine venvs `venv-whisper` / `venv-gigaam`; weights in sibling `asr-models/`). Launched by `ASRManager.swift`.
- `Soma/scout_pipeline_module/`, `Soma/gateway/`, `Soma/soma_mcp_server.py`: legacy evidence-compiler / MCP gateway — retained only as the System Status backend.

## Commands

Run Python tests:

```bash
PYTHONPATH=/Users/daliys/Daliys/Swift/Soma/Soma \
PYTHONDONTWRITEBYTECODE=1 \
TMPDIR=/tmp \
/opt/homebrew/bin/python3 -m unittest discover -s tests -p 'test_*.py'
```

Build the macOS app:

```bash
xcodebuild -project Soma.xcodeproj -scheme Soma -configuration Debug -destination 'platform=macOS' build
```

Check gateway status:

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --status-json --project-root /Users/daliys/Daliys/Swift/Soma
```

## Product Rules

- Do not add new first-layer features until Soma has been used on at least five real tasks.
- Before the next feature wave, prove three real tasks with useful packets and at least one live Soma follow-up when context is missing.
- Keep `Rus to Prompt` and `Tests` as the primary routes.
- Keep advanced tooling (MCP config, Graphify/projectmem, Local AI, logs, benchmarks, token utilities) under the Advanced section / System Status, not the main flow.
- Treat optional systems as optional, not as scary failures.
- Keep Graphify managed by Soma under `~/.soma/graphs`; use it as project-only ranking hints, not raw packet context. Unity graphs scan `Assets/` only.
- Prefer changes that make the app calmer, clearer, and faster to use.

## Acceptance Notes

A useful run makes it clear which model gives the best output for a prompt at acceptable latency and token cost. `Model Stats` and `Tests` are the product truth source: they show per-model results across translation, improver, and confidence stages so you can compare and pick.

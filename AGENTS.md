# Soma Agent Guide

## Start Here

- This is an Xcode project, not a Swift Package. The primary macOS SwiftUI target is `Soma`; shared state starts in `Soma/SomaApp.swift`, and route composition starts in `Soma/ContentView.swift`. `SomaVoiceServer` and `SomaTests` are separate targets.
- The current product direction is in `README.md` and `SOMA.md`: the app's main workflows are `Rus to Prompt` and `Tests`. The Python gateway is retained for System Status/MCP, not as the primary UI.
- The Python entrypoint is `Soma/soma_mcp_server.py`, which delegates to `Soma/gateway/server.py`; the packet compiler lives in `Soma/scout_pipeline_module/`. Read `docs/ai-development-guide.md` before changing this backend.
- For non-trivial bugs, regressions, or architecture work, follow the projectmem workflow in root `CLAUDE.md` when tools are available; never edit `.projectmem/` directly.

## Commands

Run from the repository root. Python uses the Homebrew interpreter and plain `unittest`; pytest is not the local runner:

```bash
PYTHONPATH="$PWD/Soma" PYTHONDONTWRITEBYTECODE=1 TMPDIR=/tmp \
/opt/homebrew/bin/python3 -m unittest discover -s tests -p 'test_*.py'
```

For a focused module with top-level `test_` functions, use the repository helper:

```bash
PYTHONPATH="$PWD/Soma" PYTHONDONTWRITEBYTECODE=1 TMPDIR=/tmp \
/opt/homebrew/bin/python3 Scripts/run_pytest_style_tests.py tests/test_ground_truth_consensus.py
```

Universal non-Unity acceptance:

```bash
PYTHONPATH="$PWD/Soma" PYTHONDONTWRITEBYTECODE=1 TMPDIR=/tmp \
/opt/homebrew/bin/python3 Soma/verify_soma_universal_workflow.py \
  --fixtures tests/fixtures/projects --budget fast
```

Swift build/test commands use the Xcode project and require full Xcode, not only Command Line Tools:

```bash
xcodebuild -project Soma.xcodeproj -scheme Soma -configuration Debug -destination 'platform=macOS' build
xcodebuild test -project Soma.xcodeproj -scheme Soma -destination 'platform=macOS'
```

## Constraints

- Keep the public MCP catalog at exactly 12 `soma_*` tools; never expose raw `unity_*` or direct Nexus tools to clients.
- The deterministic path must work without Ollama, Unity, or Nexus. Translation, Graphify, and local-model stages are optional and must degrade or fall back without blocking it.
- Keep logs and audit reports metadata-only by default. Raw prompts, packets, source, tool bodies, and transcripts require explicit local opt-in.
- Graphify is project-scoped ranking metadata stored under `~/.soma/graphs`; do not inject raw graph output or trigger full semantic extraction automatically. Unity graphs scan `Assets/` only.
- Preserve `run_id`/`task_id` through MCP, audit, logging, and benchmark changes; update tests and docs when public response shapes change.
- Do not commit generated or machine-local data: `graphify-out/`, `.soma/`, `.projectmem/`, `DerivedData/`, or `buildServer.json`.
- Keep `.code-linter.json` at its base limits: 300 file lines, 50 function lines, nesting depth 4, 5 parameters, 5 prose-comment lines, 50 doc-comment lines, and 2 top-level types. Fix pre-existing violations separately; do not relax the policy.

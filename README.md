# Soma

Soma is a universal local-first evidence compiler and MCP gateway for large coding models. It prepares compact, evidence-backed project packets before Codex, Gemini, Claude, or another large model spends context on raw repositories, full diffs, long logs, or verbose plugin tools.

Soma works without Unity. Unity/Nexus is an optional plugin path used only when a Unity project and Nexus server are available.

## Current Status

| Area | Status |
|---|---|
| MCP gateway | `Soma/soma_mcp_server.py` stable entrypoint |
| Public tool catalog | 12 `soma_*` tools |
| Core readiness | Universal verifier passes across fixture project types |
| Deterministic path | Works without Ollama, Unity, or Nexus |
| Local AI | Optional ranked/analyst stages via Ollama |
| Unity/Nexus | Optional plugin, skipped by default universal workflow |
| Tests | Python suite expected: 81 tests |
| Swift app | macOS build expected to succeed |

## What Soma Does

Soma builds bounded packets for real coding work:

- Detects project type across Swift, Python, JS/TS, Go, Rust, C/C++, Java/Kotlin, PHP, Ruby, shell/script, SQL/config, Unity, and generic mixed repos.
- Scans files, manifests, configs, logs, git status, and git diff summaries.
- Selects relevant evidence for implementation, debug, review, and changes prompts.
- Enforces token budgets and reports omitted raw context.
- Logs tool calls, latency, token estimates, selected project, packet size, evidence counts, analysis stages, operation savings, and estimated context reduction.
- Optionally uses local Ollama models after deterministic evidence selection.
- Optionally calls Nexus Unity through compact Soma tools when Unity/Nexus is online.

## Public MCP Tools

Big AI clients should see Soma tools only:

```text
soma_prepare_context
soma_get_map
soma_ask
soma_code_context
soma_debug
soma_review
soma_delta
soma_remember
soma_scene
soma_inspect
soma_apply
soma_execute
```

Raw `unity_*` tools should not be exposed in the Soma workflow.

## Quickstart

Run status:

```bash
cd /Users/daliys/Daliys/Swift/Soma
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --status-json --project-root /path/to/project
```

Print client config:

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --print-client-config codex --project-root /path/to/project
```

Run a direct tool call:

```bash
PYTHONPATH=/Users/daliys/Daliys/Swift/Soma/Soma \
PYTHONDONTWRITEBYTECODE=1 \
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py \
  --project-root /path/to/project \
  --run-tool soma_prepare_context \
  '{"goal":"Debug recent changes and prepare compact evidence","budget":"fast","depth":"deterministic"}'
```

## Soma Packet Mode V1

The first supported AI workflow is packet prompt mode:

1. Run `soma_prepare_context` for the selected project and task.
2. Pass the returned packet to Codex, Gemini, Claude, or another model as compact context.
3. Compare against a direct-agent baseline with `soma_agent_ab_benchmark.py`.

Live MCP tool use from Codex/Gemini is still experimental because local CLIs differ in approval and tool-call behavior. Packet mode is the default path for real token-savings validation.

## Canonical Verification

Python tests:

```bash
PYTHONPATH=/Users/daliys/Daliys/Swift/Soma/Soma \
PYTHONDONTWRITEBYTECODE=1 \
TMPDIR=/tmp \
/opt/homebrew/bin/python3 -m unittest discover -s tests -p 'test_*.py'
```

Universal non-Unity acceptance:

```bash
PYTHONPATH=/Users/daliys/Daliys/Swift/Soma/Soma \
PYTHONDONTWRITEBYTECODE=1 \
TMPDIR=/tmp \
/opt/homebrew/bin/python3 Soma/verify_soma_universal_workflow.py \
  --fixtures tests/fixtures/projects \
  --budget fast
```

Estimated context reduction benchmark:

```bash
PYTHONPATH=/Users/daliys/Daliys/Swift/Soma/Soma \
PYTHONDONTWRITEBYTECODE=1 \
TMPDIR=/tmp \
/opt/homebrew/bin/python3 Soma/soma_token_benchmark.py \
  --fixtures tests/fixtures/projects \
  --model-profile gpt-5.5 \
  --budget fast \
  --baseline both
```

Opt-in benchmark for the selected real project:

```bash
/opt/homebrew/bin/python3 Soma/soma_token_benchmark.py \
  --project-root /path/to/project \
  --model-profile gpt-5.5 \
  --budget fast \
  --baseline both
```

Observed agent A/B benchmark:

```bash
/opt/homebrew/bin/python3 Soma/soma_agent_ab_benchmark.py \
  --scenario /path/to/scenario.json \
  --agents codex,gemini
```

The A/B benchmark compares direct agent runs against packet-prompt runs with Soma context. It uses real CLI usage fields when available and transcript estimates otherwise.

Scenario tasks can include quality checks:

```json
{
  "expected_files": ["CooldownPolicy.swift", "NudgeScheduler.swift"],
  "must_mention": ["midnight"],
  "must_not_claim": ["delete settings"],
  "manual_acceptance_notes": "Answer should explain whether the quiet-hours interval crosses midnight correctly."
}
```

Swift build:

```bash
xcodebuild -project Soma.xcodeproj -scheme Soma -configuration Debug -destination 'platform=macOS' build
```

## Generated Data

Graphify output is generated runtime data. `graphify-out/` is ignored by git. Regenerate it when graph-backed answers need a fresh project map.

Soma writes runtime reports and logs under the user home directory:

```text
~/.soma/logs/soma_YYYYMMDD.jsonl
~/.soma/logs/session_stats.json
~/.soma/acceptance/universal/latest.json
~/.soma/token_stats.json
~/.soma/token_stats/token_stats_YYYYMMDD-HHMMSS.json
~/.soma/agent_benchmarks/latest.json
~/.soma/agent_benchmarks/agent_benchmark_YYYYMMDD-HHMMSS.json
```

## Documentation

- `docs/architecture.md`: system design and data flow.
- `docs/operations.md`: daily use, setup, logs, MCP config, troubleshooting.
- `docs/testing.md`: test and acceptance commands.
- `docs/roadmap.md`: current engineering roadmap.
- `docs/ai-development-guide.md`: how an AI/developer should navigate and modify Soma.
- `docs/history/etap-report.md`: historical implementation summary.

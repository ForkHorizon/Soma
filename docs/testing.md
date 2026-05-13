# Soma Testing

Run commands from `/Users/daliys/Daliys/Swift/Soma`.

## Python Unit Suite

```bash
PYTHONPATH=/Users/daliys/Daliys/Swift/Soma/Soma \
PYTHONDONTWRITEBYTECODE=1 \
TMPDIR=/tmp \
/opt/homebrew/bin/python3 -m unittest discover -s tests -p 'test_*.py'
```

Expected current shape: 81 tests pass.

## Python Compile Check

```bash
PYTHONPATH=/Users/daliys/Daliys/Swift/Soma/Soma \
PYTHONDONTWRITEBYTECODE=1 \
TMPDIR=/tmp \
/opt/homebrew/bin/python3 -m py_compile \
  Soma/token_calculator.py \
  Soma/universal_fixtures.py \
  Soma/verify_soma_universal_workflow.py \
  Soma/soma_token_benchmark.py \
  Soma/soma_agent_ab_benchmark.py \
  Soma/soma_mcp_server.py
```

## Universal Acceptance

```bash
PYTHONPATH=/Users/daliys/Daliys/Swift/Soma/Soma \
PYTHONDONTWRITEBYTECODE=1 \
TMPDIR=/tmp \
/opt/homebrew/bin/python3 Soma/verify_soma_universal_workflow.py \
  --fixtures tests/fixtures/projects \
  --budget fast
```

Acceptance requirements:

- core status is `ok`
- Unity/Nexus plugin status is `skipped`
- every fixture returns non-empty evidence and a packet under budget
- deterministic depth passes without requiring Ollama
- ranked/analyst depth passes when Ollama is online, otherwise degrades

## Estimated Context Benchmark

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

Output is written to:

```text
~/.soma/token_stats.json
~/.soma/token_stats/token_stats_YYYYMMDD-HHMMSS.json
```

For a real project, run the opt-in form only when the selected project should be scanned:

```bash
/opt/homebrew/bin/python3 Soma/soma_token_benchmark.py \
  --project-root /path/to/project \
  --model-profile gpt-5.5 \
  --budget fast \
  --baseline both
```

## Observed Agent A/B Benchmark

Create a scenario JSON with a real project and read-only tasks, then run:

```bash
PYTHONPATH=/Users/daliys/Daliys/Swift/Soma/Soma \
PYTHONDONTWRITEBYTECODE=1 \
TMPDIR=/tmp \
/opt/homebrew/bin/python3 Soma/soma_agent_ab_benchmark.py \
  --scenario /path/to/scenario.json \
  --agents codex,gemini
```

The report is written to:

```text
~/.soma/agent_benchmarks/latest.json
~/.soma/agent_benchmarks/agent_benchmark_YYYYMMDD-HHMMSS.json
```

The benchmark is expected to stay read-only at this stage. Failed agent runs must not produce savings; reports mark comparisons as unavailable unless direct and with-Soma runs both complete.

For v1, this is the primary AI-readiness check. It runs:

- `direct_agent`: Codex/Gemini inspect the project normally.
- `with_soma_packet`: Soma precompiles a packet and the agent receives that compact context.
- `with_soma_mcp_experimental`: documented only; not part of default A/B scoring yet.

Scenario tasks may include `expected_files`, `must_mention`, `must_not_claim`, and `manual_acceptance_notes`. Savings are counted only when the agent run succeeds and the quality rubric does not fail. If `soma_prepare_context` returns `degraded`, the with-Soma run is skipped and savings are unavailable.

## MCP Status Smoke

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --status-json --project-root /path/to/project
```

Confirm `tool_count` is 12 and no `unity_*` tools are listed.

## Swift Build

```bash
xcodebuild -project Soma.xcodeproj -scheme Soma -configuration Debug -destination 'platform=macOS' build
```

## Optional Live Unity Verifier

Use only when Nexus is running in a matching Unity project:

```bash
PYTHONPATH=/Users/daliys/Daliys/Swift/Soma/Soma \
PYTHONDONTWRITEBYTECODE=1 \
TMPDIR=/tmp \
/opt/homebrew/bin/python3 Soma/verify_soma_live_workflow.py \
  --project-root /path/to/unity/project \
  --live-unity \
  --run-apply \
  --cleanup-apply
```

Default non-Unity readiness does not require this command.

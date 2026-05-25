# Soma Testing

Run commands from `/Users/daliys/Daliys/Swift/Soma`.

## Python Unit Suite

```bash
PYTHONPATH=/Users/daliys/Daliys/Swift/Soma/Soma \
PYTHONDONTWRITEBYTECODE=1 \
TMPDIR=/tmp \
/opt/homebrew/bin/python3 -m unittest discover -s tests -p 'test_*.py'
```

Expected current shape: 131 tests pass.

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
  Soma/soma_language_optimizer.py \
  Soma/soma_audit.py \
  Soma/verify_soma_mcp_clients.py \
  Soma/soma_mcp_server.py
```

## Prompt Language Optimization Checks

The unit suite covers:

- Russian prompt normalization to English.
- Preservation of exact paths, filenames, symbols, commands, URLs, JSON, stack traces, and code/code-fence spans.
- Translation fallback that does not block `soma_prepare_context`.
- Metadata-only logs with prompt hashes and language fields, not raw non-English prompts.
- Moodling quiet-hours regression where a Russian task still selects the key English-named files.

For a manual check, run:

```bash
PYTHONPATH=/Users/daliys/Daliys/Swift/Soma/Soma \
PYTHONDONTWRITEBYTECODE=1 \
TMPDIR=/tmp \
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py \
  --project-root /path/to/project \
  --run-tool soma_prepare_context \
  '{"goal":"Проверь, почему quiet hours может ломаться после полуночи в CooldownPolicy.swift","budget":"fast","depth":"deterministic"}'
```

Expected behavior: response contains `language_optimization`; packet metadata says the original language was Russian; the packet goal is English; the full Russian prompt is not copied into the packet.

## Task Audit Checks

The unit suite covers:

- `run_id` and `task_id` propagation through `soma_prepare_context`, structured logs, and audit reports.
- Codex live helper guidance in `next_calls`, including `client="codex"` and `workflow="live_mcp"` tracking.
- Metadata-only default behavior: raw prompt, packet, source, transcript, and tool bodies are not written to JSONL or audit JSON.
- Raw-capture opt-in writing local artifacts under `~/.soma/audit/raw/<run_id>/`.
- Missing evidence detection for unresolved filenames, paths, and symbols from the prompt.
- Manual quality marking with `accepted`, `wrong`, and `needs_more_evidence`.
- Analytics aggregation for local model usage counts by model/stage/status.

Manual checks:

```bash
PYTHONPATH=/Users/daliys/Daliys/Swift/Soma/Soma \
PYTHONDONTWRITEBYTECODE=1 \
TMPDIR=/tmp \
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py \
  --project-root /path/to/project \
  --run-tool soma_prepare_context \
  '{"goal":"Investigate MissingThing.swift and CooldownPolicy.swift","budget":"fast","depth":"deterministic","run_id":"manual_audit_check","task_id":"quiet_hours"}'
```

```bash
/opt/homebrew/bin/python3 Soma/soma_audit.py --latest
/opt/homebrew/bin/python3 Soma/soma_audit.py --run manual_audit_check
/opt/homebrew/bin/python3 Soma/soma_audit.py --mark manual_audit_check --status needs_more_evidence --notes "Expected file was not selected."
```

Expected behavior: `latest.json` references the run, unresolved prompt references appear under `missing_evidence`, and the report contains hashes/counts rather than raw prompt text.

## Usefulness Loop Checks

Manual acceptance for the current product loop:

1. Prepare a packet from the app.
2. Copy the packet into Codex.
3. Use `Use with Codex` to copy the live helper protocol.
4. Make at least one follow-up Soma tool call with the same `run_id` and `task_id`.
5. Mark the packet `Useful` or `Not useful`.

Expected behavior: `Packets` shows the run, selected files, usefulness, final outcome, missed files if any, and live Soma tool-call count. The 3-task proof metric only becomes complete after three useful real runs.

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
  --agents codex,gemini,hermes
```

The report is written to:

```text
~/.soma/agent_benchmarks/latest.json
~/.soma/agent_benchmarks/agent_benchmark_YYYYMMDD-HHMMSS.json
```

The benchmark is expected to stay read-only at this stage. Failed agent runs must not produce savings; reports mark comparisons as unavailable unless direct and with-Soma runs both complete.

For v1, this is the primary AI-readiness check. It runs:

- `direct_agent`: Hermes/Codex/Gemini inspect the project normally.
- `with_soma_packet`: Soma precompiles a packet and the agent receives that compact context.
- `with_soma_mcp_experimental`: documented only; not part of default A/B scoring yet.

Scenario tasks may include `expected_files`, `must_mention`, `must_not_claim`, `must_not_mention_files`, and `manual_acceptance_notes`. Savings are counted only when the agent run succeeds and the quality rubric does not fail. If `soma_prepare_context` returns `degraded`, the with-Soma run is skipped and savings are unavailable.

Hermes regression fixture:

```bash
/opt/homebrew/bin/python3 Soma/soma_agent_ab_benchmark.py \
  --scenario tests/fixtures/agent_scenarios/moodling_quiet_hours_hermes.json \
  --agents hermes
```

This fixture must reject hallucinated files such as `QuietHoursManager.swift` and `Configuration.swift`; savings remain unavailable unless the acceptance rubric passes.

## MCP Status Smoke

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --status-json --project-root /path/to/project
```

Confirm `tool_count` is 12 and no `unity_*` tools are listed.

## MCP Client Config And Live Smoke

Install or verify client configs:

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --install-codex-config --project-root /path/to/project
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --install-gemini-config --project-root /path/to/project
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --install-hermes-config --project-root /path/to/project
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --verify-client-config codex --project-root /path/to/project
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --verify-client-config gemini --project-root /path/to/project
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --verify-client-config hermes --project-root /path/to/project
```

Run the guarded smoke:

```bash
PYTHONPATH=/Users/daliys/Daliys/Swift/Soma/Soma \
PYTHONDONTWRITEBYTECODE=1 \
TMPDIR=/tmp \
/opt/homebrew/bin/python3 Soma/verify_soma_mcp_clients.py \
  --project-root /path/to/project \
  --clients codex,gemini,hermes
```

Expected report paths:

```text
~/.soma/mcp_smoke/latest.json
~/.soma/mcp_smoke/mcp_smoke_YYYYMMDD-HHMMSS.json
```

Acceptance checks:

- Codex, Gemini, and Hermes configs point to `soma_mcp_server.py` and the selected project root.
- Direct Unity/Nexus MCP servers are not exposed to the clients.
- `initialize` and `tools/list` succeed.
- Tool catalog has exactly 12 `soma_*` tools with schemas.
- Safe read-only tools are exercised.
- Unity/plugin tools are `skipped` with `plugin_guarded` unless Nexus is online and matches the selected project.
- Reports and logs contain metadata only, not raw source, prompts, transcripts, or tool bodies.

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

# Soma

Soma is a universal local-first evidence compiler, agent context backend, and MCP gateway for large coding models. It prepares compact, evidence-backed project packets before Hermes, Codex, Gemini, Claude, or another large model spends context on raw repositories, full diffs, long logs, or verbose plugin tools.

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
| Tests | Python suite expected: 125 tests |
| Swift app | macOS build expected to succeed |

## What Soma Does

Soma builds bounded packets for real coding work:

- Detects project type across Swift, Python, JS/TS, Go, Rust, C/C++, Java/Kotlin, PHP, Ruby, shell/script, SQL/config, Unity, and generic mixed repos.
- Scans files, manifests, configs, logs, git status, and git diff summaries.
- Selects relevant evidence for implementation, debug, review, and changes prompts.
- Normalizes non-English task prompts to English before selection and packet generation, while preserving paths, symbols, commands, URLs, JSON, stack traces, and code snippets.
- Enforces token budgets and reports omitted raw context.
- Logs tool calls, local model calls, latency, token estimates, selected project, packet size, evidence counts, missing evidence, analysis stages, operation savings, estimated context reduction, and audit run IDs.
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
2. Pass the returned packet to Hermes, Codex, Gemini, Claude, or another model as compact context.
3. If the agent needs more context, keep it inside Soma: `soma_code_context` for focused source snippets, `soma_debug` for bugs, `soma_delta` after edits/tests, and `soma_review` before final review.
4. Pass the packet `run_id` and `task_id` into follow-up Soma calls with `client="codex"` and `workflow="live_mcp"` so the app can show whether live tools actually helped.
5. Compare against a direct-agent baseline with `soma_agent_ab_benchmark.py`.

Packet mode remains the default path for real token-savings validation, but Codex-first live helper mode is the next usefulness loop. Soma does not replace Hermes runtime features such as messaging, cron, delegation, or skills; it supplies the local evidence/context layer those runtimes can call first and audit after the task.

## Task Audit Trail

Every packet run gets a local audit trace so real AI work can be reviewed after the fact. The trace shows what project and prompt were used, how Soma normalized the prompt, which packet was created, which evidence files were selected, what Soma could not find, which related Soma tools ran, and whether the result was accepted or rejected.

By default Soma stores metadata, hashes, counts, statuses, and paths only. Raw prompts, packets, and transcripts are local opt-in artifacts:

```bash
SOMA_AUDIT_ENABLED=1
SOMA_AUDIT_RAW_CAPTURE=0
SOMA_AUDIT_RETENTION_DAYS=14
SOMA_AUDIT_RAW_RETENTION_DAYS=7
```

Inspect or mark a run:

```bash
/opt/homebrew/bin/python3 Soma/soma_audit.py --latest
/opt/homebrew/bin/python3 Soma/soma_audit.py --run <run_id>
/opt/homebrew/bin/python3 Soma/soma_audit.py --mark <run_id> --status accepted --notes "Matched expected files."
```

## Prompt Language Optimization

Soma optimizes task prompts before evidence selection. English prompts pass through unchanged. Non-English prompts are translated to English when a local translator is available, then the English task is used for intent classification, file matching, Graphify query, and packet `Goal`.

The original non-English prompt is not copied into the packet by default. Packets only include concise metadata such as original language, translation status, and expected answer language. Source snippets, logs, stack traces, paths, commands, URLs, JSON, and code references are protected and restored exactly.

Default environment:

```bash
SOMA_TRANSLATION_ENABLED=1
SOMA_TRANSLATION_PROVIDER=local
SOMA_TRANSLATOR_MODEL=gemma4:e4b
```

If local translation is unavailable, Soma falls back to the original prompt and marks `language_optimization.status` as `failed_fallback`. This does not block deterministic packets. Free cloud translation is opt-in only and requires both `SOMA_TRANSLATION_PROVIDER=free_cloud` and `SOMA_FREE_TRANSLATION_URL`.

## Optional GPT Referee

Soma can run a small cloud referee before the final packet is returned. This does not send source previews or full packets; it sends the task, collection plan, evidence paths, kinds, reasons, symbols, and current quality flags. Use it to catch weak packets such as version/changelog tasks where required evidence is missing.

The referee is off by default:

```bash
SOMA_CLOUD_REFEREE_PROVIDER=openai
SOMA_OPENAI_API_KEY=...
SOMA_OPENAI_REFEREE_MODEL=gpt-5.4-mini
SOMA_CLOUD_REFEREE_POLICY=degraded_only
```

The default policy only calls GPT when deterministic/local evidence is already weak, missing required context, or mismatched with the collection plan. The model is intentionally isolated behind `SOMA_OPENAI_REFEREE_MODEL` so it can be swapped later without changing the packet pipeline.

## AI Agent Setup And MCP Smoke

The macOS app can install and verify Soma-only MCP configs for Codex, Gemini, and Hermes. From CLI:

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --install-codex-config --project-root /path/to/project
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --install-gemini-config --project-root /path/to/project
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --install-hermes-config --project-root /path/to/project
```

Before using live MCP tools, run the guarded smoke:

```bash
/opt/homebrew/bin/python3 Soma/verify_soma_mcp_clients.py \
  --project-root /path/to/project \
  --clients codex,gemini,hermes
```

The smoke checks initialization, the 12-tool catalog, input schemas, safe read-only calls, and plugin guards. It does not expose raw Unity/Nexus tools and does not write raw source or transcripts to reports.

## Using SOMA With Hermes

Hermes should call Soma as an evidence/context backend before doing broad file or terminal exploration.

Install and verify Hermes MCP config:

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --install-hermes-config --project-root /path/to/project
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --verify-client-config hermes --project-root /path/to/project
```

Run guarded smoke for all first-class clients:

```bash
/opt/homebrew/bin/python3 Soma/verify_soma_mcp_clients.py \
  --project-root /path/to/project \
  --clients codex,gemini,hermes
```

Run the Moodling quiet-hours Hermes scenario:

```bash
/opt/homebrew/bin/python3 Soma/soma_agent_ab_benchmark.py \
  --scenario tests/fixtures/agent_scenarios/moodling_quiet_hours_hermes.json \
  --agents hermes
```

Hermes is optional. If the Hermes CLI or `~/.hermes/config.yaml` is missing, Soma reports `degraded` with install guidance instead of failing the whole MCP smoke.

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

Graphify output is generated runtime data. Legacy project-local `graphify-out/` folders are still readable and ignored by git, but Soma-managed graphs now live under:

```text
~/.soma/graphs/projects/<project_id>/graphify-out/
~/.soma/graphs/index.json
```

`project_id` is a stable hash of the normalized project root. Soma checks managed storage first, then legacy project-local graphs. For Unity project roots, Graphify scans only `Assets/` while still storing the graph under the project id; this avoids `Library/`, `Packages/`, cache, and generated-project noise. Prepare Packet uses Graphify only as compact ranking hints and skips graph hints when the graph is missing, stale, degraded, or outside the selected project.

Useful Graphify maintenance commands:

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --check-graphify-tool-json
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --refresh-managed-graph --project-root /path/to/project
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --diagnose-graph-json --project-root /path/to/project
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --graph-tree-json --project-root /path/to/project
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --graph-callflow-json --project-root /path/to/project
```

Full graph rebuilds use `graphify extract` and must stay explicit because docs/semantic extraction can spend model/API tokens.

Soma writes runtime reports and logs under the user home directory:

```text
~/.soma/logs/soma_YYYYMMDD.jsonl
~/.soma/logs/session_stats.json
~/.soma/acceptance/universal/latest.json
~/.soma/token_stats.json
~/.soma/token_stats/token_stats_YYYYMMDD-HHMMSS.json
~/.soma/mcp_smoke/latest.json
~/.soma/mcp_smoke/mcp_smoke_YYYYMMDD-HHMMSS.json
~/.soma/agent_benchmarks/latest.json
~/.soma/agent_benchmarks/agent_benchmark_YYYYMMDD-HHMMSS.json
~/.soma/audit/latest.json
~/.soma/audit/runs/audit_YYYYMMDD-HHMMSS_<run_id>.json
~/.soma/audit/raw/<run_id>/prompt.txt
~/.soma/audit/raw/<run_id>/packet.txt
~/.soma/graphs/projects/<project_id>/graphify-out/graph.json
~/.soma/graphs/projects/<project_id>/graphify-out/GRAPH_REPORT.md
~/.soma/graphs/projects/<project_id>/graphify-out/GRAPH_TREE.html
~/.soma/graphs/projects/<project_id>/graphify-out/<project>-callflow.html
```

## Documentation

- `docs/architecture.md`: system design and data flow.
- `docs/operations.md`: daily use, setup, logs, MCP config, troubleshooting.
- `docs/testing.md`: test and acceptance commands.
- `docs/roadmap.md`: current engineering roadmap.
- `docs/ai-development-guide.md`: how an AI/developer should navigate and modify Soma.
- `docs/history/etap-report.md`: historical implementation summary.

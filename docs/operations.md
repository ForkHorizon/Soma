# Soma Operations

## Daily Workflow

1. Open the Soma macOS app or run the CLI.
2. Select a project root.
3. Install or verify Codex/Gemini/Hermes MCP configs from `AI Agent Setup`.
4. Run `MCP Smoke` before using live tools.
5. Prepare a packet for the concrete task.
6. Give the returned packet to Codex, Gemini, Hermes, Claude, or another coding agent as compact project context.
7. For Codex work, copy `Use with Codex` from the app and keep follow-up context inside Soma.
8. Mark the packet `Useful` or `Not useful` after the task.
9. Review the Task Audit trace if the answer is weak, surprising, or missing files.

For Russian or other non-English tasks, write the task naturally. Soma attempts to normalize the task intent to English before evidence selection and packet generation, while preserving exact file paths, symbols, commands, URLs, JSON, stack traces, and code snippets.

## CLI Status

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --status-json --project-root /path/to/project
```

Expected server shape:

- `status: ok`
- `tool_count: 12`
- tool names all start with `soma_`

## Client Config

Print Codex config:

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --print-client-config codex --project-root /path/to/project
```

Install Codex config:

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --install-codex-config --project-root /path/to/project
```

Verify Codex config:

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --verify-client-config codex
```

Rollback latest Soma Codex backup:

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --rollback-codex-config
```

Install Gemini config:

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --install-gemini-config --project-root /path/to/project
```

Verify Gemini config:

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --verify-client-config gemini --project-root /path/to/project
```

Rollback latest Soma Gemini backup:

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --rollback-gemini-config
```

Print Hermes config:

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --print-client-config hermes --project-root /path/to/project
```

Install Hermes config:

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --install-hermes-config --project-root /path/to/project
```

Verify Hermes config:

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --verify-client-config hermes --project-root /path/to/project
```

Claude remains copy-only config output for now.

Hermes/Codex/Gemini live MCP support is guarded by config verification and MCP smoke. Packet Mode remains the stable default starting point, and Codex-first live helper mode is the follow-up path for missing context. Soma is the evidence/context layer; Hermes still owns runtime features like messaging, cron, delegation, and skills.

## Codex Live Helper Protocol

After a packet is prepared, use `Use with Codex` in the app to copy the protocol for the selected project and task. Codex should:

1. Start from the prepared packet.
2. Call `soma_code_context` for one missing source area instead of scanning broadly.
3. Call `soma_debug` for bugs before guessing.
4. Call `soma_delta` after edits or tests.
5. Call `soma_review` before final review when regressions or missing tests matter.
6. Pass the packet `run_id`, `task_id`, `client="codex"`, and `workflow="live_mcp"` on follow-up Soma calls.

The `Packets` screen uses those correlated logs to show whether the agent actually used Soma after the initial packet.

## Using SOMA With Hermes

Hermes integration is intentionally context-first: configure Hermes to see Soma MCP, then make `soma_prepare_context` the first step for project questions before broad file or terminal scans.

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --install-hermes-config --project-root /path/to/project
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --verify-client-config hermes --project-root /path/to/project
/opt/homebrew/bin/python3 Soma/verify_soma_mcp_clients.py \
  --project-root /path/to/project \
  --clients codex,gemini,hermes
```

Hermes A/B benchmark fixture:

```bash
/opt/homebrew/bin/python3 Soma/soma_agent_ab_benchmark.py \
  --scenario tests/fixtures/agent_scenarios/moodling_quiet_hours_hermes.json \
  --agents hermes
```

The Moodling fixture requires Hermes to name the real quiet-hours files and rejects invented files such as `QuietHoursManager.swift` and `Configuration.swift`. Missing Hermes remains `degraded`, not a global setup failure.

## Prompt Language Optimization

Default behavior:

```bash
SOMA_TRANSLATION_ENABLED=1
SOMA_TRANSLATION_PROVIDER=local
SOMA_TRANSLATOR_MODEL=gemma4:e4b
```

When the prompt is already English, Soma records `original_english` and continues. When the prompt is non-English, Soma tries local English normalization and records `translated` if successful. If local translation is unavailable, the run continues with `failed_fallback`; deterministic evidence compilation must still work.

The agent-facing packet is English in v1. The full original prompt is not included in the packet or logs by default. Logs and reports contain metadata only: language, status, engine, protected span count, prompt token counts, and a prompt hash.

Opt-in cloud translation is disabled unless both are set:

```bash
SOMA_TRANSLATION_PROVIDER=free_cloud
SOMA_FREE_TRANSLATION_URL=https://...
```

## Optional GPT Referee

Use the cloud referee only when packet quality matters more than staying fully local. It sends compact metadata only, not source previews or raw packet text, and can mark the packet `degraded` when evidence is missing.

```bash
SOMA_CLOUD_REFEREE_PROVIDER=openai
SOMA_OPENAI_API_KEY=...
SOMA_OPENAI_REFEREE_MODEL=gpt-5.4-mini
SOMA_CLOUD_REFEREE_POLICY=degraded_only
```

With the default `degraded_only` policy, GPT is called only after deterministic/local checks already report weak evidence, missing required context, or plan mismatch. Keep the model behind `SOMA_OPENAI_REFEREE_MODEL`; it is expected to change as we compare quality and cost.

## MCP Smoke

Run the guarded client smoke before trusting live tools:

```bash
/opt/homebrew/bin/python3 Soma/verify_soma_mcp_clients.py \
  --project-root /path/to/project \
  --clients codex,gemini,hermes
```

The smoke checks initialize, `tools/list`, 12 Soma schemas, safe read-only calls, and plugin guards. Unity/Nexus tools are skipped unless the selected project is a matching live Unity project. Reports store metadata, counts, hashes, statuses, and durations only.

## Logs And Reports

Runtime files live outside the repo:

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
```

Use logs to inspect tool calls, local model calls, errors, latency, token estimates, operation savings, estimated context reduction, budget usage, project type, selected project, evidence counts, and local model stage status.

`System Status` shows three token measurement lines:

- `Operation`: concrete per-call outputs Soma avoided, measured against the full Soma response the agent receives.
- `Estimated`: raw-context versus Soma packet reduction.
- `Observed A/B`: latest direct-agent versus with-Soma benchmark, if one has been run.
- `Prompt Lang`: prompt-level reduction from non-English to English normalization, if present.

`Measure Context` runs only the opt-in context benchmark for the selected project. Observed A/B runs require a scenario JSON and are launched from CLI so the operator can choose real tasks and acceptance expectations.

`AI Agent Readiness` shows Codex/Gemini/Hermes config health, latest MCP smoke, and Unity plugin guard status. Configs marked `wrong project root` should be reinstalled for the selected project.

`Local Model Today` in `Logs & Analytics` counts every Ollama-backed request made by Soma, split by model and stage: `translation`, `ranker`, `analyst`, `summary`, or legacy chat. Failed calls are counted too, because they still cost time and explain degraded stages.

## Task Audit Trail

Soma creates an audit trace for packet runs and attaches the same `run_id` to related tool calls when the client passes it through. The audit trace is the main debugging view for real projects: it shows the prompt hash, normalized prompt hash, packet hash, selected evidence, missing requested paths/symbols, skipped optional stages, and quality status.

Default privacy policy:

- JSON reports and JSONL logs store metadata, hashes, counts, statuses, paths, and durations.
- Raw prompt, packet, and transcript files are not captured by default.
- Raw capture is local opt-in for the next run only from the Swift app, or by setting `SOMA_AUDIT_RAW_CAPTURE=1` in the environment.

Report paths:

```text
~/.soma/audit/latest.json
~/.soma/audit/runs/audit_YYYYMMDD-HHMMSS_<run_id>.json
~/.soma/audit/raw/<run_id>/prompt.txt
~/.soma/audit/raw/<run_id>/packet.txt
```

CLI:

```bash
/opt/homebrew/bin/python3 Soma/soma_audit.py --latest
/opt/homebrew/bin/python3 Soma/soma_audit.py --run <run_id>
/opt/homebrew/bin/python3 Soma/soma_audit.py --mark <run_id> --status accepted --notes "Evidence matched the task."
/opt/homebrew/bin/python3 Soma/soma_audit.py --mark <run_id> --status wrong --notes "Missed the real scheduler file."
/opt/homebrew/bin/python3 Soma/soma_audit.py --mark <run_id> --status needs_more_evidence --notes "Need logs and tests."
```

Quality labels are deliberately separate from token savings. A run with excellent savings but missing evidence should be marked `needs_more_evidence` or `wrong`, not treated as successful.

Example A/B scenario:

```json
{
  "project_root": "/path/to/project",
  "agents": ["codex", "gemini", "hermes"],
  "tasks": [
    {
      "id": "debug_recent_change",
      "prompt": "Find the likely cause of the recent failing behavior and explain the relevant files.",
      "expected_result": "Names the relevant changed file and a plausible cause.",
      "expected_files": ["src/core.py"],
      "must_mention": ["root cause"],
      "must_not_claim": ["rewrite the app"],
      "read_only": true
    }
  ]
}
```

Run it:

```bash
/opt/homebrew/bin/python3 Soma/soma_agent_ab_benchmark.py \
  --scenario /path/to/scenario.json \
  --agents codex,gemini,hermes
```

Hermes regression scenario:

```bash
/opt/homebrew/bin/python3 Soma/soma_agent_ab_benchmark.py \
  --scenario tests/fixtures/agent_scenarios/moodling_quiet_hours_hermes.json \
  --agents hermes
```

## Graphify

`graphify-out/` is generated data and ignored by git.

Regenerate graph data when graph-backed answers or architecture work need a fresh index. Soma still works without Graphify; graph absence is `skipped`, not a core failure. `soma_prepare_context` uses project-only graph lookup by default so an unrelated Unity or old project graph is not injected into a packet.

## Optional Unity/Nexus

Unity/Nexus is an optional plugin path. It is skipped in universal acceptance.

For live Unity checks:

1. Open the Unity project.
2. Start Nexus in the Unity editor.
3. Ensure Nexus project path matches the selected project root.
4. Run the live verifier with `--live-unity`.

Wrong-project or offline Nexus must degrade safely and must not block generic Soma tools.

## Troubleshooting

- Empty evidence: run universal verifier and inspect `discovered_files` and `evidence_count`.
- Token budget exceeded: check `omitted` metadata and packet budget.
- Ollama unavailable: use `depth=deterministic`; ranked/analyst should degrade.
- Direct Unity tools visible in client: reinstall or verify Codex config so only Soma is exposed.

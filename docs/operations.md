# Soma Operations

## Daily Workflow

1. Open the Soma macOS app or run the CLI.
2. Select a project root.
3. Start Soma MCP for that project.
4. Run `soma_prepare_context` for the concrete task.
5. Give the returned packet to the AI agent as compact project context.
6. Use live MCP tools only as an experimental follow-up.

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

Gemini and Claude are copy-only config outputs for now.

Codex/Gemini live MCP support is not the default readiness path yet. Codex may require approval bypass or an interactive approval flow, and Gemini exposes tools differently by approval mode. For real token-savings tests, use Soma Packet Mode and the A/B benchmark.

## Logs And Reports

Runtime files live outside the repo:

```text
~/.soma/logs/soma_YYYYMMDD.jsonl
~/.soma/logs/session_stats.json
~/.soma/acceptance/universal/latest.json
~/.soma/token_stats.json
~/.soma/token_stats/token_stats_YYYYMMDD-HHMMSS.json
~/.soma/agent_benchmarks/latest.json
~/.soma/agent_benchmarks/agent_benchmark_YYYYMMDD-HHMMSS.json
```

Use logs to inspect tool calls, errors, latency, token estimates, operation savings, estimated context reduction, budget usage, project type, selected project, evidence counts, and local model stage status.

`System Status` shows three token measurement lines:

- `Operation`: concrete per-call outputs Soma avoided, measured against the full Soma response the agent receives.
- `Estimated`: raw-context versus Soma packet reduction.
- `Observed A/B`: latest direct-agent versus with-Soma benchmark, if one has been run.

`Measure Context` runs only the opt-in context benchmark for the selected project. Observed A/B runs require a scenario JSON and are launched from CLI so the operator can choose real tasks and acceptance expectations.

Example A/B scenario:

```json
{
  "project_root": "/path/to/project",
  "agents": ["codex", "gemini"],
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
  --agents codex,gemini
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

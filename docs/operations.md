# Soma Operations

## Daily Workflow

1. Open the Soma macOS app or run the CLI.
2. Select a project root.
3. Start Soma MCP for that project.
4. Configure the AI client to connect to Soma only.
5. Start work with `soma_get_map` or `soma_prepare_context`.
6. Use the compact packet first; request only narrow missing context if needed.

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

## Logs And Reports

Runtime files live outside the repo:

```text
~/.soma/logs/soma_YYYYMMDD.jsonl
~/.soma/logs/session_stats.json
~/.soma/acceptance/universal/latest.json
~/.soma/token_stats.json
~/.soma/token_stats/token_stats_YYYYMMDD-HHMMSS.json
```

Use logs to inspect tool calls, errors, latency, token estimates, token savings, budget usage, project type, selected project, evidence counts, and local model stage status.

`System Status` shows the latest packet savings and an opt-in `Measure Selected Project` action. The action runs the project benchmark only on demand.

## Graphify

`graphify-out/` is generated data and ignored by git.

Regenerate graph data when graph-backed answers or architecture work need a fresh index. Soma still works without Graphify; graph absence should degrade context quality, not break deterministic evidence compilation.

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

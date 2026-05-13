# Soma Architecture

Soma is a local-first evidence compiler plus MCP gateway. Its job is to turn a repository, git state, logs, graph context, optional local model analysis, and optional Unity plugin data into compact packets for large coding models.

## Runtime Shape

```text
Big AI client
  -> Soma Packet Mode prompt or Soma MCP gateway
  -> stable 12-tool Soma catalog
  -> deterministic Scout pipeline
  -> optional Graphify context
  -> optional Ollama ranker/analyst
  -> optional Unity/Nexus plugin
```

The deterministic path is the baseline. It must work when Ollama is offline and when Unity/Nexus is skipped or unavailable.

## Gateway

`Soma/soma_mcp_server.py` is the stable script configured by MCP clients. It delegates to `Soma/gateway/server.py`.

Gateway responsibilities are split:

- `gateway/tool_registry.py`: stable public tool catalog.
- `gateway/client_config.py`: Codex install/verify/rollback and copy-only config snippets.
- `gateway/status.py`: status payloads for CLI and Swift UI.
- `gateway/jsonrpc.py`: lightweight line-delimited daemon used by Swift process control.
- `gateway/tools/`: implementation of context, query, memory, and optional Nexus tools.

Packet Mode is the v1 production-like workflow for Codex/Gemini. Live MCP tool calls remain available but experimental until CLI approval behavior and usage accounting are stable across clients.

## Scout Pipeline

`Soma/scout_pipeline_module/` compiles evidence:

- detect project type
- scan files with Go daemon or Python fallback
- build repo index
- summarize git status/diff without raw full diff leakage
- select evidence by prompt mode
- gate packet quality so weak evidence returns `degraded`
- build a token-budgeted packet
- optionally rank/analyze with local models

Supported project classes include Swift, Python, JS/TS, Go, Rust, C/C++, Java/Kotlin, PHP, Ruby, script repos, SQL/config/log-heavy generic repos, and Unity.

## Observability

Structured logs are metadata-only by default:

```text
~/.soma/logs/soma_YYYYMMDD.jsonl
~/.soma/logs/session_stats.json
```

Tool logs include tool name, status, latency, token estimates, project type, packet mode, budget, evidence count, discovered files, changed file count, analysis depth, and analysis stage statuses.

Analytics reads those JSONL logs through `Soma/soma_analytics.py`.

## Token Measurement

`Soma/token_profiles.json` is the shared profile table for Python and Swift. `Soma/token_calculator.py` loads it, uses optional `tiktoken` when available, and falls back to chars-per-token estimates.

Soma separates token measurement into three levels so the UI does not present theoretical context reduction as observed agent savings:

- `estimated_context_reduction`: secondary estimate of raw task/repo context versus the Soma packet.
- `operation_savings`: primary per-tool runtime metric comparing concrete avoided outputs such as `git status`, `git diff`, and selected files/logs/configs against the full Soma tool response.
- `observed_agent_usage`: A/B benchmark comparing direct Codex/Gemini runs with packet-prompt runs that include Soma context.

`Soma/soma_token_savings.py` computes the runtime `token_savings` object for `soma_prepare_context`. The old top-level `saved_tokens` and `savings_pct` fields remain for compatibility, but `token_savings.primary_metric` identifies which nested metric they represent.

`Soma/token_calculator.py` provides shared token estimates for:

- `soma_prepare_context`
- analytics
- benchmark scenarios
- Swift Token Calculator profile alignment

`Soma/soma_token_benchmark.py` compares task-candidate and opt-in raw repository plus git/log baselines against Soma packets. It writes `~/.soma/token_stats.json` and timestamped history under `~/.soma/token_stats/`.

`Soma/soma_agent_ab_benchmark.py` runs read-only direct-vs-Soma scenarios through Codex and Gemini. It writes `~/.soma/agent_benchmarks/latest.json` and timestamped history. Reports store counts, hashes, statuses, durations, usage fields, and quality-rubric results, not raw private transcripts. Savings are unavailable when the Soma packet is degraded or either agent run fails the rubric.

## Graphify

Graphify is optional. `soma_prepare_context` uses project-only graph lookup by default and records `graphify: skipped` when no graph exists for the selected project. Cross-project graphs must not be injected into packets for universal/non-Unity work.

## Optional Unity/Nexus Plugin

Unity/Nexus is not part of the core readiness gate. Default universal verification skips it.

When enabled with `--live-unity`, Soma calls Nexus through compact tools such as `soma_scene`, `soma_inspect`, `soma_apply`, and `soma_execute`. Raw Unity/Nexus tools remain hidden from Big AI.

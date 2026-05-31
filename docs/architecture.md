# Soma Architecture

Soma is a local-first evidence compiler, agent context backend, and MCP gateway. Its job is to turn a repository, git state, logs, graph context, optional local model analysis, and optional Unity plugin data into compact packets for large coding models.

## Runtime Shape

```text
Hermes/Codex/Gemini/Claude
  -> Soma Packet Mode prompt or Soma MCP gateway
  -> stable 12-tool Soma catalog
  -> prompt language optimization
  -> task audit context
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
- `gateway/client_config.py`: Codex/Gemini/Hermes install and verify helpers, Codex/Gemini rollback, and copy-only snippets for other clients.
- `gateway/status.py`: status payloads for CLI and Swift UI.
- `gateway/jsonrpc.py`: lightweight line-delimited daemon used by Swift process control and guarded MCP smoke.
- `gateway/tools/`: implementation of context, query, memory, and optional Nexus tools.

Packet Mode is the v1 production-like workflow for Hermes, Codex, and Gemini. Codex-first live helper mode starts from that packet, then uses the existing 12 Soma tools for focused follow-up context, debug evidence, deltas, and review. Users should run config verification and MCP smoke before trusting live tools. Soma deliberately stays out of agent-runtime responsibilities such as messaging, cron, delegation, skill marketplaces, and long-lived task orchestration.

## Scout Pipeline

`Soma/scout_pipeline_module/` compiles evidence:

- normalize non-English task prompts to English without touching protected code/path/log spans
- detect project type
- scan files with Go daemon or Python fallback
- build repo index
- summarize git status/diff without raw full diff leakage
- select evidence by prompt mode
- gate packet quality so weak evidence returns `degraded`
- build a token-budgeted packet
- optionally rank/analyze with local models
- optionally call a cloud GPT referee with compact metadata only to catch missing required evidence before packet delivery

Supported project classes include Swift, Python, JS/TS, Go, Rust, C/C++, Java/Kotlin, PHP, Ruby, script repos, SQL/config/log-heavy generic repos, and Unity.

## Prompt Language Optimization

`Soma/soma_language_optimizer.py` runs before intent classification and evidence selection. It detects language, protects sensitive spans, translates only the user task intent to English, restores protected spans exactly, and returns metadata under `language_optimization`.

Default policy is local-first:

- `SOMA_TRANSLATION_ENABLED=1`
- `SOMA_TRANSLATION_PROVIDER=local`
- `SOMA_TRANSLATOR_MODEL`, falling back to existing local model env vars and then `gemma4:e4b`

Translation is best-effort. If no local model is reachable or translation fails, Soma uses the original prompt and returns `failed_fallback` without failing `soma_prepare_context`. Optional cloud translation requires explicit opt-in and a configured URL. Logs store hashes, language, token counts, and status metadata only, not raw prompts.

## Observability

Structured logs are metadata-only by default:

```text
~/.soma/logs/soma_YYYYMMDD.jsonl
~/.soma/logs/session_stats.json
```

Tool logs include tool name, status, latency, token estimates, project type, packet mode, budget, evidence count, discovered files, changed file count, analysis depth, and analysis stage statuses.
Language optimization logs add source language, translation status, engine, protected span count, and prompt-level token savings. Raw original prompts are not written.
Local model logs use `local_model_call` events and count every Ollama request, including translation, ranker, analyst, summary, and legacy chat paths. They record model name, stage, status, latency, estimated input/output tokens, JSON-mode flag, and errors without storing raw prompts or model responses.
The optional GPT referee is opt-in through `SOMA_CLOUD_REFEREE_PROVIDER=openai`. It sends task and evidence metadata, not file previews or packet bodies. Its default policy is `SOMA_CLOUD_REFEREE_POLICY=degraded_only`, so GPT is called only when deterministic/local checks already report weak evidence, missing required context, or plan mismatch. Its model is configured with `SOMA_OPENAI_REFEREE_MODEL`.

Analytics reads those JSONL logs through `Soma/soma_analytics.py`.

## Task Audit Trail

`Soma/soma_audit.py` correlates packet generation, MCP calls, agent benchmark runs, and quality review under a stable `run_id` and optional `task_id`.

Audit reports live outside the repo:

```text
~/.soma/audit/latest.json
~/.soma/audit/runs/audit_YYYYMMDD-HHMMSS_<run_id>.json
~/.soma/audit/raw/<run_id>/
```

The default report is metadata-only. It records project root, project type, workflow, prompt hashes, packet hash, selected evidence, unresolved requested files/symbols, skipped optional stages, expected next calls, compact tool-call metadata, and manual or rubric quality status. It does not store raw prompts, packets, source bodies, transcripts, or tool payloads unless `SOMA_AUDIT_RAW_CAPTURE=1` is explicitly enabled for a local run.

Audit events are also written into the structured JSONL log with the same `run_id`, so `Logs & Analytics` can filter a task trace across packet mode and live MCP calls.

## Usefulness Loop

The app treats usefulness as a first-class product signal. Each real packet run records usefulness, missed files, why it failed, whether the agent used live Soma tools, live tool-call count, and final outcome.

`Prepare Packet` is the start of the workflow. `Use with Codex` copies a short protocol that tells Codex when to call `soma_code_context`, `soma_debug`, `soma_delta`, `soma_review`, and `soma_apply`. `Packets` is not a raw log viewer; it is a quality dashboard with a 3-task proof metric and visible not-useful reasons.

## Token Measurement

`Soma/token_profiles.json` is the shared profile table for Python and Swift. `Soma/token_calculator.py` loads it, uses optional `tiktoken` when available, and falls back to chars-per-token estimates.

Soma separates token measurement into three levels so the UI does not present theoretical context reduction as observed agent savings:

- `prompt_language_savings`: secondary prompt-level metric comparing original prompt tokens to normalized English prompt tokens.
- `estimated_context_reduction`: secondary estimate of raw task/repo context versus the Soma packet.
- `operation_savings`: primary per-tool runtime metric comparing concrete avoided outputs such as `git status`, `git diff`, and selected files/logs/configs against the full Soma tool response.
- `observed_agent_usage`: A/B benchmark comparing direct Hermes/Codex/Gemini runs with packet-prompt runs that include Soma context.

`Soma/soma_token_savings.py` computes the runtime `token_savings` object for `soma_prepare_context`. The old top-level `saved_tokens` and `savings_pct` fields remain for compatibility, but `token_savings.primary_metric` identifies which nested metric they represent.

`Soma/token_calculator.py` provides shared token estimates for:

- `soma_prepare_context`
- analytics
- benchmark scenarios
- Swift Token Calculator profile alignment

`Soma/soma_token_benchmark.py` compares task-candidate and opt-in raw repository plus git/log baselines against Soma packets. It writes `~/.soma/token_stats.json` and timestamped history under `~/.soma/token_stats/`.

`Soma/soma_agent_ab_benchmark.py` runs read-only direct-vs-Soma scenarios through Codex, Gemini, and optional Hermes. It writes `~/.soma/agent_benchmarks/latest.json` and timestamped history. Reports store counts, hashes, statuses, durations, usage fields, tool markers when discoverable, and quality-rubric results, not raw private transcripts. Savings are unavailable when the Soma packet is degraded or either agent run fails the rubric.

`Soma/verify_soma_mcp_clients.py` verifies Codex/Gemini/Hermes config health and runs a guarded live smoke against Soma's stdio daemon. It writes `~/.soma/mcp_smoke/latest.json` plus timestamped history. Plugin/mutating tools are schema/guard checked unless Unity/Nexus is online and matched to the selected project.

## Graphify

Graphify is optional. `soma_prepare_context` uses project-only graph lookup by default and records `graphify: skipped` when no graph exists for the selected project. Cross-project graphs must not be injected into packets for universal/non-Unity work.

Soma owns canonical graph storage under `~/.soma/graphs/projects/<project_id>/graphify-out/`, where `project_id` is `sha256(normalized_absolute_project_root)[:16]`. `~/.soma/graphs/index.json` records project root, display name, graph build version, update time, node/edge counts, managed storage path, and legacy graph paths.

The graph source root can differ from the selected project root. For normal projects, Soma scans the project root. For Unity project roots, Soma scans only `<project_root>/Assets` and records `graphScope=unity_assets`; `Library/`, `Packages/`, generated solution files, and cache folders are intentionally excluded from Graphify extraction.

Graph lookup order is:

1. Soma-managed graph for the selected project.
2. Legacy project-local `graphify-out`.
3. Known nested package graph inside the selected project.

The adapter must not fall back to hard-coded cross-project graphs. Stale or diagnostics-degraded graphs are skipped for packet ranking. Graphify query and affected output may boost selected files, but raw graph output is not injected into the packet.

Maintenance actions are explicit:

- AST-only refresh: `GRAPHIFY_OUT=<managed_graphify_out> graphify update <graph_source_root>`; Unity `Assets/` refresh uses `--force` so older whole-project graph noise can be removed.
- Full rebuild: `graphify extract <graph_source_root> --out <managed_project_dir>`.
- Diagnostics: `graphify diagnose multigraph --json --graph <graph.json>`.
- Optional reports: `graphify tree` and `graphify export callflow-html`.

Full rebuilds are user-triggered only because semantic extraction over docs/images can spend model/API tokens.

## Optional Unity/Nexus Plugin

Unity/Nexus is not part of the core readiness gate. Default universal verification skips it.

When enabled with `--live-unity`, Soma calls Nexus through compact tools such as `soma_scene`, `soma_inspect`, `soma_apply`, and `soma_execute`. Raw Unity/Nexus tools remain hidden from Big AI.

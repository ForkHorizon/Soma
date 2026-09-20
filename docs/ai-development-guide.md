# AI Development Guide

This guide is for the next AI or engineer modifying Soma.

## Read First

1. `README.md`
2. `docs/architecture.md`
3. `docs/testing.md`
4. `Soma/gateway/tool_registry.py`
5. `Soma/scout_pipeline_module/pipeline.py`

## Mental Model

Soma has two layers:

- Gateway layer: exposes 12 stable MCP tools and hides verbose integrations.
- Scout pipeline layer: compiles compact deterministic evidence packets.

Unity/Nexus is a plugin path. Do not make core readiness depend on it.
Soma Packet Mode is the first production-like AI workflow. Codex-first live helper mode builds on that packet: use `soma_code_context` for missing context, `soma_debug` for bugs, `soma_delta` after edits/tests, and `soma_review` before final review while preserving `run_id`/`task_id`.

## Key Files

| Area | Files |
|---|---|
| MCP entrypoint | `Soma/soma_mcp_server.py`, `Soma/gateway/server.py` |
| Tool catalog | `Soma/gateway/tool_registry.py` |
| Context tools | `Soma/gateway/tools/context.py`, `Soma/gateway/tools/query.py` |
| Optional Unity tools | `Soma/gateway/tools/nexus.py` |
| Evidence pipeline | `Soma/scout_pipeline_module/` |
| Prompt language optimization | `Soma/soma_language_optimizer.py` |
| Logging and audit | `Soma/soma_logger.py`, `Soma/soma_analytics.py`, `Soma/soma_audit.py` |
| Universal acceptance | `Soma/verify_soma_universal_workflow.py` |
| Token measurement | `Soma/soma_token_savings.py`, `Soma/soma_token_benchmark.py`, `Soma/soma_agent_ab_benchmark.py` |
| Swift app | `Soma/ViewModels/`, `Soma/Views/` |

## Safe Change Rules

- Keep `.code-linter.json` at the Code Linter base settings without overrides:
  300 file lines, 50 function lines, nesting depth 4, 5 parameters, 5 prose
  comment lines, 50 doc-comment lines, and 2 top-level types per file. Never
  relax these values to accommodate existing violations; fix unrelated legacy
  violations in separate tasks.
- Preserve the 12-tool public catalog unless intentionally changing a public interface.
- Keep deterministic packets working without Ollama.
- Keep prompt language optimization best-effort: failures must fall back, not block packets.
- Do not log or packetize the full original non-English prompt by default.
- Keep audit metadata private by default: hashes/counts/paths only, raw artifacts only behind explicit opt-in.
- Propagate `run_id` and `task_id` through packet generation, tool logs, MCP calls, and benchmark reports when available.
- Follow-up live MCP calls should also pass `client="codex"` and `workflow="live_mcp"` when the packet came from Codex usage.
- Log every local model request as `local_model_call` with model, stage, status, latency, and token estimates; do not log raw prompts or responses.
- Keep `soma_prepare_context` project-scoped: no cross-project Graphify context in packets.
- Treat Graphify as optional ranking metadata. Use managed storage first, skip stale/degraded graphs, and never inject raw graph output into normal packets.
- For Unity project roots, Graphify source scope is `Assets/` only. Do not scan `Library/`, `Packages/`, generated IDE files, or caches into managed graphs.
- Return `degraded` when evidence selection lacks a strong task match.
- Keep non-Unity acceptance passing before touching Unity/Nexus behavior.
- Do not log full request/response bodies by default.
- Do not commit generated `graphify-out/` data.
- Do not run full Graphify extraction automatically; it may spend semantic model/API tokens.
- Prefer small behavior-preserving refactors with tests.

## Helper Scripts

These scripts are development helpers, not runtime entrypoints:

- `Soma/clean_tool_imports.py`
- `Soma/cst_split.py`
- `Soma/cst_extract_core.py`

Before deleting or renaming them, search the repo and run the full Python test suite.

## Public Response Shape

Core tools should return compact JSON with stable fields such as:

- `status`
- `summary`
- `evidence`
- `omitted`
- `next_calls`
- `project_type`
- `packet_mode`
- `estimated_tokens`
- `analysis_stages`
- `language_optimization`
- `estimated_context_reduction`
- `operation_savings`
- `token_savings`
- `audit`

If a response shape changes, update tests and docs together.

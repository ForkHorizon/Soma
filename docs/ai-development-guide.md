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

## Key Files

| Area | Files |
|---|---|
| MCP entrypoint | `Soma/soma_mcp_server.py`, `Soma/gateway/server.py` |
| Tool catalog | `Soma/gateway/tool_registry.py` |
| Context tools | `Soma/gateway/tools/context.py`, `Soma/gateway/tools/query.py` |
| Optional Unity tools | `Soma/gateway/tools/nexus.py` |
| Evidence pipeline | `Soma/scout_pipeline_module/` |
| Logging | `Soma/soma_logger.py`, `Soma/soma_analytics.py` |
| Universal acceptance | `Soma/verify_soma_universal_workflow.py` |
| Token benchmark | `Soma/soma_token_benchmark.py` |
| Swift app | `Soma/ViewModels/`, `Soma/Views/` |

## Safe Change Rules

- Preserve the 12-tool public catalog unless intentionally changing a public interface.
- Keep deterministic packets working without Ollama.
- Keep non-Unity acceptance passing before touching Unity/Nexus behavior.
- Do not log full request/response bodies by default.
- Do not commit generated `graphify-out/` data.
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

If a response shape changes, update tests and docs together.

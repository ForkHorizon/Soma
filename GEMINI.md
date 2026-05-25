# AI Development Guide: Soma

Soma is a universal local-first evidence compiler and MCP gateway. Treat Unity/Nexus as an optional plugin path, not as a core dependency.

## Source Of Truth

Read these first:

- `README.md` for operator quickstart.
- `docs/architecture.md` for system design.
- `docs/operations.md` for runtime workflow.
- `docs/testing.md` for canonical verification.
- `docs/ai-development-guide.md` before changing code.

## Architecture Map

- Stable entrypoint: `Soma/soma_mcp_server.py`
- Gateway orchestration: `Soma/gateway/server.py`
- Tool registry: `Soma/gateway/tool_registry.py`
- Config mutation: `Soma/gateway/client_config.py`
- Status payloads: `Soma/gateway/status.py`
- Core evidence pipeline: `Soma/scout_pipeline_module/`
- Prompt language optimization: `Soma/soma_language_optimizer.py`
- Structured logging: `Soma/soma_logger.py`
- Analytics: `Soma/soma_analytics.py`
- Task audit trail: `Soma/soma_audit.py`
- Universal verifier: `Soma/verify_soma_universal_workflow.py`
- Token measurement: `Soma/soma_token_savings.py`, `Soma/soma_token_benchmark.py`, `Soma/soma_agent_ab_benchmark.py`

## Hard Rules

- Big AI clients connect to Soma only.
- Do not expose raw `unity_*` or direct Nexus tools in Soma docs/config examples.
- Deterministic `soma_prepare_context` must work without Ollama, Unity, or Nexus.
- Non-English prompts should be normalized to English when possible, but translation failure must fall back safely.
- Never log the full original non-English prompt by default; store metadata and hashes only.
- Keep Task Audit metadata-only by default; raw prompt/packet/transcript capture is opt-in and local.
- Preserve and propagate `run_id`/`task_id` when adding tools, logs, benchmarks, or UI traces.
- Every local model request must be logged as `local_model_call` with model, stage, status, latency, and token estimates only.
- Local ranker/analyst failures must degrade, not block deterministic packets.
- `tools/list` stays stable for v1.
- Keep logs metadata-oriented by default; do not log full request/response bodies.
- Keep operation savings, estimated context reduction, and observed A/B usage separate.
- Treat Soma Packet Mode as the starting point for real AI workflow; live Codex/Gemini MCP should follow the audited Soma protocol.
- Live protocol: start with `soma_prepare_context`, use `soma_code_context` when context is missing, `soma_debug` for bugs, `soma_delta` after edits/tests, and `soma_review` before final review.
- Preserve `run_id`/`task_id` and pass `client="codex"` plus `workflow="live_mcp"` on follow-up tool calls when available.
- `soma_prepare_context` must use project-only Graphify and return `degraded` when selected evidence is weak.
- `graphify-out/` is generated and ignored by git.

## Canonical Commands

```bash
PYTHONPATH=/Users/daliys/Daliys/Swift/Soma/Soma \
PYTHONDONTWRITEBYTECODE=1 \
TMPDIR=/tmp \
/opt/homebrew/bin/python3 -m unittest discover -s tests -p 'test_*.py'
```

```bash
PYTHONPATH=/Users/daliys/Daliys/Swift/Soma/Soma \
PYTHONDONTWRITEBYTECODE=1 \
TMPDIR=/tmp \
/opt/homebrew/bin/python3 Soma/verify_soma_universal_workflow.py \
  --fixtures tests/fixtures/projects \
  --budget fast
```

```bash
xcodebuild -project Soma.xcodeproj -scheme Soma -configuration Debug -destination 'platform=macOS' build
```

## Change Guidance

- Prefer behavior-preserving refactors in small slices.
- Add or update tests for public MCP response shape, logs, budgets, or project detection changes.
- Keep fixture coverage universal and non-Unity by default.
- Run `git diff --check` before handing work back.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

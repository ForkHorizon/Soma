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
- Structured logging: `Soma/soma_logger.py`
- Analytics: `Soma/soma_analytics.py`
- Universal verifier: `Soma/verify_soma_universal_workflow.py`
- Token measurement: `Soma/soma_token_savings.py`, `Soma/soma_token_benchmark.py`, `Soma/soma_agent_ab_benchmark.py`

## Hard Rules

- Big AI clients connect to Soma only.
- Do not expose raw `unity_*` or direct Nexus tools in Soma docs/config examples.
- Deterministic `soma_prepare_context` must work without Ollama, Unity, or Nexus.
- Local ranker/analyst failures must degrade, not block deterministic packets.
- `tools/list` stays stable for v1.
- Keep logs metadata-oriented by default; do not log full request/response bodies.
- Keep operation savings, estimated context reduction, and observed A/B usage separate.
- Treat Soma Packet Mode as the default real AI workflow; live Codex/Gemini MCP is experimental.
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

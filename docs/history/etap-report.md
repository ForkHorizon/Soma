# Historical Etap Report

This file preserves the useful engineering history from the older root-level implementation reports. Current usage instructions live in `README.md` and `docs/`.

## Direction

Soma was built to reduce Big AI context waste by exposing a small Soma MCP catalog instead of raw project and plugin surfaces. The original Unity/Nexus workflow motivated the gateway, but the current readiness gate is universal and does not require Unity.

## Implemented Foundation

- Soma MCP gateway with 12 stable `soma_*` tools.
- Scout pipeline for deterministic evidence compilation.
- Swift app for project selection, status, server lifecycle, logs, and config actions.
- Codex config install/verify/rollback.
- Graphify support when generated graph data is available.
- Optional local Ollama ranker and analyst stages.
- Optional Unity/Nexus path through compact Soma tools.
- Structured logging and analytics.
- Universal project fixture certification and token benchmark.

## Important Lessons

- Big AI should connect to Soma only.
- Direct raw Unity/Nexus exposure creates tool and context bloat.
- Deterministic evidence selection is the reliability baseline.
- Local AI is useful only after Soma has narrowed context.
- Acceptance reports and logs are required before real-case testing.
- Generated graph data should be reproducible, not treated as source.

## Superseded Items

Older claims about missing MCP stdio support, failing tests, mock PIDs, and Unity/Nexus being the main readiness blocker are obsolete. See `docs/testing.md` for current verification commands.

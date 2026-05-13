# Soma Roadmap

## Core Evidence Compiler

- Keep deterministic evidence compilation reliable across supported project types.
- Treat Soma Packet Mode as the first production-like workflow for Codex/Gemini.
- Keep evidence quality gates strict: a compact packet without strong relevant evidence must return degraded.
- Improve scanner daemon error handling so fallback paths are quiet and observable.
- Add more fixture variants for large repos, monorepos, and sparse git states.

## Observability

- Surface latest universal acceptance and token benchmark reports in the Swift UI.
- Add log filters for project type, tool, status, budget, and analysis depth.
- Add a compact daily report view based on `soma_analytics.py`.

## Token Measurement

- Keep operation savings, estimated context reduction, and observed A/B usage separate in reports and UI.
- Calibrate real scenarios on larger repos with direct Codex/Gemini runs versus Soma packet runs.
- Count observed savings only when both agent runs complete and the quality rubric passes.
- Track raw baseline, avoided operation outputs, Soma packet size, budget hit rate, and omitted context over time.
- Keep token profile estimates shared between backend and Swift UI.

## Optional Unity/Nexus Plugin

- Keep Unity/Nexus skipped by default in universal readiness.
- Strengthen wrong-project guard before any live apply.
- Add cleanup verification after `soma_apply`.
- Keep raw Unity/Nexus tools hidden from Big AI.

## Code Readability

- Keep `gateway/server.py` as a thin CLI/MCP orchestration layer.
- Continue splitting single-responsibility helpers out of large modules when behavior can be preserved.
- Add tests before changing public MCP response shapes.
- Document ambiguous helper scripts before deleting them.

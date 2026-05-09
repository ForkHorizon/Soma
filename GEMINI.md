# GEMINI Context: Soma / NexusSoma

## Project Role

Soma is the local-first evidence compiler and MCP gateway for NexusSoma.

**Note on Nexus Integration:**
Nexus is a separate repository providing an MCP server for the Unity Editor. Soma functions independently as a codebase analyzer (using Graphify, AST scanners, and git), but is also designed to integrate seamlessly with Nexus. When used together, Soma acts as a unified gateway, hiding the raw, verbose Nexus tools from Big AI and wrapping them in compact, efficient workflows.

Primary rule:

```text
Big AI clients should connect to Soma only.
Do not connect Big AI directly to raw Nexus Unity for the Soma workflow.
```

Soma exposes a small, stable MCP tool catalog and hides raw Nexus Unity tools behind compact Soma tools. This reduces tool-definition bloat, exploratory calls, full scene/component dumps, raw diff/log spam, and cold-start rediscovery.

## Current Architecture

- Swift app: `/Users/daliys/Daliys/Swift/Soma/Soma/ContentView.swift`
- Soma MCP gateway: `/Users/daliys/Daliys/Swift/Soma/Soma/soma_mcp_server.py`
- Scout Pipeline: `/Users/daliys/Daliys/Swift/Soma/Soma/scout_pipeline.py`
- Live verifier: `/Users/daliys/Daliys/Swift/Soma/Soma/verify_soma_live_workflow.py`
- Logging & Analytics: `/Users/daliys/Daliys/Swift/Soma/Soma/soma_logger.py` & `soma_analytics.py`
- Acceptance Suite: `/Users/daliys/Daliys/Swift/Soma/Soma/soma_acceptance.py`
- Detailed report: `/Users/daliys/Daliys/Swift/Soma/reportD.md`

The app controls:

- Soma MCP server start/stop
- selected project root
- Nexus connection status
- Graphify graph status
- Codex config verify/install/rollback
- live Soma/Nexus verifier

## MCP Tool Policy

Big AI should see exactly these Soma tools:

- `soma_prepare_context`
- `soma_get_map`
- `soma_ask`
- `soma_code_context`
- `soma_scene`
- `soma_inspect`
- `soma_debug`
- `soma_review`
- `soma_delta`
- `soma_apply`
- `soma_execute`
- `soma_remember`

Raw `unity_*` tools should not be visible to Big AI when using the Soma workflow.

## Current Workflow

1. Select a project root in Soma.
2. Start Soma MCP from the Swift app.
3. Install or copy Codex/Gemini/Claude config that points to Soma.
4. Big AI calls `soma_get_map` or `soma_prepare_context`.
5. Soma gathers deterministic evidence, Graphify context, memory, and Nexus state if online.
6. Big AI uses the compact packet first.
7. Unity edits go through `soma_apply`, not raw Nexus tools.

## Codex Config State

Codex is the only client with mutation support:

- `Install Codex` backs up `~/.codex/config.toml`, writes `[mcp_servers.soma]`, and removes direct `[mcp_servers.nexus-unity]`.
- `Verify Client` checks whether direct Nexus exposure remains.
- `Rollback Codex` restores the newest Soma backup.

Gemini and Claude remain copy-only until Codex is fully proven.

## Nexus Unity State

Nexus Unity remains the powerful hidden Unity control layer.

Live Unity operations require:

1. Open UnityTestForNexus.
2. Open `Window > Nexus Unity`.
3. Click `START SERVER`.
4. Refresh Soma status.
5. Run live verification.

If Nexus is offline, Soma should return compact degraded/error JSON. Offline Nexus is not a reason to fail deterministic packet generation.

## Graphify

This project has a Graphify knowledge graph at `graphify-out/`.

Rules:

- Before architecture/codebase answers, read `graphify-out/GRAPH_REPORT.md` when useful.
- For cross-module questions, prefer `graphify query`, `graphify path`, or `graphify explain` over broad raw grep.
- After code changes, run `graphify update .` when graph freshness matters.
- Do not dump huge graph output into chat or documentation.

Known graph paths:

- Soma: `/Users/daliys/Daliys/Swift/Soma/graphify-out/graph.json`
- UnityTestForNexus: `/Users/daliys/Daliys/UnityProjects/UnityTestForNexus/graphify-out/graph.json`

## Testing

Run Python tests:

```bash
cd /Users/daliys/Daliys/Swift/Soma
PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 -m unittest discover -s tests -p 'test_*.py'
```

Expected current result:

```text
Ran 31 tests
OK
```

Run Swift build:

```bash
cd /Users/daliys/Daliys/Swift/Soma
xcodebuild -project Soma.xcodeproj -scheme Soma -configuration Debug -destination 'platform=macOS' build
```

## Development Rules

- Keep deterministic mode as the default path.
- Local ranker/analyst failures must not block deterministic packets.
- Do not store raw conversations in project memory.
- Do not expose direct Nexus tools to Big AI in Soma docs/config examples.
- Keep `tools/list` stable for v1.
- Update `reportD.md` or README when changing the architecture or workflow.

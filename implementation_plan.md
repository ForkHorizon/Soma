# Soma: Master Implementation Plan — From Prototype to Production

## Current State Assessment

After analyzing all source files, tests, Swift UI, and documentation:

### What Works
- 12 `soma_*` tool functions exist in `soma_mcp_server.py` (1278 lines)
- Scout Pipeline module with 14 Python files for evidence compilation
- Swift macOS app with project selection, Ollama control, evidence relay UI
- `SomaMCPCoordinator.swift` — basic stdio MCP server that delegates to Python
- Graphify graph exists (488 nodes, 962 edges)
- 31 tests exist (but **5 are failing**)
- Config install/verify/rollback for Codex implemented

### What's Broken / Missing

> [!CAUTION]
> **Tests are failing:** 3 failures + 2 errors in the test suite (expected 30 OK, got 26 pass / 5 fail). This must be fixed first.

> [!WARNING]
> **No real MCP stdio server exists.** `soma_mcp_server.py` line 1277 prints an error: `"FastMCP removed. Run tools via python script directly..."`. The Python file is now just a CLI runner, NOT an MCP server. `SomaMCPCoordinator.swift` exists but `startSomaServer()` just sets a mock PID (`1337`) — it doesn't actually start a functioning MCP stdio server that external AI clients can connect to.

> [!WARNING]
> **Gemini CLI currently connects to Graphify directly**, not Soma. The MCP config at `~/.gemini/antigravity/mcp_config.json` points to `graphify.serve`, bypassing Soma entirely.

> [!IMPORTANT]
> **No logging/analytics infrastructure.** Activity logs are in-memory Swift arrays only. No file-based structured logs, no token tracking, no performance metrics.

---

## Stage 1: Fix Foundation (Tests + MCP Server)

**Goal:** Make the codebase green and provide a real MCP stdio server that AI clients can connect to.

**Why first:** Nothing else matters if tests fail and there's no connectable MCP server.

---

### 1.1 Fix Failing Tests

#### [MODIFY] [test_scout_pipeline.py](file:///Users/daliys/Daliys/Swift/Soma/tests/test_scout_pipeline.py)

Fix 5 failing tests:
- `test_gather_omits_raw_git_diff` — `git_diff_summary` is `None`, needs null-safe access
- `test_noise_files_are_omitted` — same `None` issue on `git_diff_summary["changed_files"]`
- `test_review_prioritizes_changed_files_above_manifest_and_logs` — `relay.py` not found in empty paths
- `test_ranker_failure_does_not_block_packet` — status returns `"skipped"` not `"failed"`
- `test_iter_project_files` (go_scanner) — `main.cpp` not in results

Root cause: Scout pipeline functions changed but tests weren't updated.

---

### 1.2 Restore Python MCP Stdio Server

#### [MODIFY] [soma_mcp_server.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_mcp_server.py)

Add a minimal JSON-RPC stdio loop at the bottom of the file (the `__main__` block). When no `--run-tool` or `--status-json` flags are passed, the server should:

1. Read JSON-RPC lines from stdin
2. Handle `initialize`, `tools/list`, and `tools/call` methods
3. Dispatch `tools/call` to the 12 `soma_*` async functions
4. Write JSON-RPC responses to stdout
5. No external dependencies (no FastMCP needed — pure stdlib)

This restores the ability for AI clients (Codex, Gemini CLI) to connect to Soma via stdio.

---

### 1.3 Update Swift Server Launch

#### [MODIFY] [SomaViewModel.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/ViewModels/SomaViewModel.swift)

`startSomaServer()` currently creates `SomaMCPCoordinator()` but doesn't actually launch a process. Change it to:
1. Launch `python3 soma_mcp_server.py --project-root <path>` as a background `Process`
2. Store the real PID
3. Track stdin/stdout pipes for the MCP session

#### [MODIFY] [SomaMCPCoordinator.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/SomaMCPCoordinator.swift)

Decide: either keep delegation to Python (simpler), or implement native Swift MCP. **Recommendation:** Keep Python as the engine, Swift as the launcher/UI. Simplify `SomaMCPCoordinator` to just be a process manager.

---

### Verification
```bash
# Tests must pass
cd /Users/daliys/Daliys/Swift/Soma
PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 -m unittest discover -s tests -p 'test_*.py'
# Expected: Ran 31 tests OK

# MCP stdio must respond to initialize
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | \
  /opt/homebrew/bin/python3 Soma/soma_mcp_server.py --project-root /Users/daliys/Daliys/Swift/Soma

# Swift build must pass
xcodebuild -project Soma.xcodeproj -scheme Soma -configuration Debug -destination 'platform=macOS' build
```

---

## Stage 2: Structured Logging & Analytics

**Goal:** Full observability — every tool call, every token estimate, every latency, every error — logged to disk with structured JSON.

**Why second:** Before connecting real AI clients, we need to see what's happening.

---

### 2.1 Python Structured Logger

#### [NEW] [soma_logger.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_logger.py)

Create a logging module that:
- Writes structured JSON lines to `~/.soma/logs/soma_YYYYMMDD.jsonl`
- Each entry: `{timestamp, level, tool, duration_ms, input_tokens, output_tokens, status, error, project_root}`
- Auto-rotates daily, keeps last 14 days
- Provides `@log_tool_call` decorator for wrapping all `soma_*` functions
- Tracks cumulative session stats in `~/.soma/logs/session_stats.json`

#### [MODIFY] [soma_mcp_server.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_mcp_server.py)

- Import and apply `@log_tool_call` to all 12 `soma_*` functions
- Log every MCP request/response in the stdio loop
- Add `estimate_tokens()` calls on both input params and output to track token flow

---

### 2.2 Token Analytics Dashboard Data

#### [NEW] [soma_analytics.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_analytics.py)

- Reads `~/.soma/logs/*.jsonl` and computes:
  - Total tokens in/out per tool, per day
  - Average latency per tool
  - Error rate per tool
  - Top 10 most expensive calls
  - Budget utilization (how often packets hit the budget limit)
- Outputs to `~/.soma/analytics/daily_report.json`
- CLI: `python3 soma_analytics.py --report today`

---

### 2.3 Swift Log Viewer

#### [MODIFY] [SomaViewModel.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/ViewModels/SomaViewModel.swift)

- Add `loadStructuredLogs()` that reads `~/.soma/logs/soma_*.jsonl`
- Parse into `[SomaLogEntry]` array

#### [NEW] [LogsView.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/Views/LogsView.swift)

- New sidebar tab: "Logs & Analytics"
- Live-tail view of recent log entries with color-coded severity
- Filter by tool name, status, date range
- Summary cards: total calls today, total tokens, error count, avg latency

#### [MODIFY] [SidebarView.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/Views/SidebarView.swift)

- Add `AppRoute.logs` case

---

### Verification
- Run `soma_prepare_context` → verify JSONL log entry written to `~/.soma/logs/`
- Run `soma_analytics.py --report today` → verify JSON output
- Open Swift app → verify Logs tab shows entries

---

## Stage 3: Graphify Integration Hardening

**Goal:** Replace fragile shell-out-to-CLI Graphify queries with the MCP adapter that's already available in this session.

**Why third:** Graphify is core to Soma's value. Shell subprocess calls are brittle and slow.

---

### 3.1 Graphify MCP Adapter

#### [MODIFY] [soma_mcp_server.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_mcp_server.py) — `GraphifyAdapter`

Replace `subprocess.run(["graphify", "query", ...])` in `GraphifyAdapter.query()` with direct Python imports from the `graphify` package, or use an in-process MCP client if the package supports it. Fallback to subprocess only if import fails.

Key changes:
- `query()` → try `from graphify import ...` first, fallback to CLI
- `god_nodes_from_report()` → also try Graphify MCP `god_nodes` tool
- Add `graph_stats()` method using Graphify's stats API
- Add error handling with structured logging

---

### 3.2 Auto-Refresh Graph on Project Change

#### [MODIFY] [SomaViewModel.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/ViewModels/SomaViewModel.swift)

- When `selectProjectRoot()` is called, check if `graphify-out/graph.json` exists and is fresh
- If stale (>24h) or missing, show a "Refresh Graph" button
- Add `refreshGraph()` that runs `graphify update .` in the project root

---

### 3.3 Enrich `soma_ask` with Deep Graph Queries

#### [MODIFY] [soma_mcp_server.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_mcp_server.py) — `soma_ask()`

Currently just calls `graphify.query()`. Enhance to:
1. Try `query_graph` (BFS) first for broad context
2. If question mentions two concepts, also try `shortest_path`
3. Include `god_nodes` in the response for orientation
4. Structured response with `graph_context`, `paths`, `key_nodes`

---

### Verification
- `soma_ask "how does evidence compilation work"` → returns graph-backed answer without subprocess
- Graph stale indicator appears in Swift UI when graph is old
- All 31+ tests still pass

---

## Stage 4: Swift UI Overhaul for Observability

**Goal:** Transform the Swift app from a basic control panel into a production dashboard.

---

### 4.1 MCP Gateway Dashboard

#### [NEW] [MCPDashboardView.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/Views/MCPDashboardView.swift)

Replace the simple "MCP Gateway" section with a dedicated dashboard:
- **Connection status:** Real-time MCP server status (PID, uptime, connected clients)
- **Tool catalog:** List of 12 tools with call counts and avg latency from logs
- **Active sessions:** Which AI client is currently connected
- **Quick actions:** Start/Stop, Config copy, Verify, Install, Rollback (already exist, consolidate)

#### [MODIFY] [SidebarView.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/Views/SidebarView.swift)

Add `AppRoute.mcpDashboard` between existing routes.

---

### 4.2 Real-Time Activity Feed

#### [MODIFY] [ContentView.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/ContentView.swift)

Add a collapsible bottom panel (like Xcode's debug area):
- Shows live stream of MCP tool calls as they happen
- Each entry: timestamp, tool name, status badge, latency, token count
- Click to expand full request/response JSON
- Color coding: green=ok, yellow=degraded, red=error

---

### 4.3 Project Health Card

#### [MODIFY] [GlobalSettingsBar.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/Views/GlobalSettingsBar.swift)

Enhance the top bar:
- Add graph status indicator (green/yellow/red dot)
- Add token budget usage sparkline (last 10 calls)
- Add "Last call" indicator with timestamp

---

### Verification
- Open app → see MCP Dashboard with tool catalog
- Run a `soma_prepare_context` → see it appear in real-time activity feed
- Graph status dot reflects actual `graphify-out/graph.json` freshness

---

## Stage 5: AI Client Integration (Codex + Gemini CLI)

**Goal:** Real AI clients connect to Soma and use it for daily work.

---

### 5.1 Gemini CLI Config

#### [MODIFY] [soma_mcp_server.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_mcp_server.py)

Update `build_client_config("gemini", ...)` to generate the correct Antigravity MCP config format:

```json
{
  "mcpServers": {
    "soma": {
      "command": "/opt/homebrew/bin/python3",
      "args": ["soma_mcp_server.py", "--project-root", "<path>"],
      "type": "stdio"
    }
  }
}
```

#### [MODIFY] MCP Config Installation

Add `--install-gemini-config` flag that:
1. Backs up `~/.gemini/antigravity/mcp_config.json`
2. Replaces `graphify` entry with `soma` entry (Soma wraps Graphify internally)
3. Verifies the config points only to Soma

---

### 5.2 Tool Schema Compliance

#### [MODIFY] [soma_mcp_server.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_mcp_server.py)

The `tools/list` response must include proper JSON Schema `inputSchema` for each tool, not just name/description. AI clients need this to know the parameters. Add:

```python
{
  "name": "soma_prepare_context",
  "description": "Compile a bounded evidence packet for implementation, debug, or review work.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "goal": {"type": "string", "description": "The task or question to prepare context for"},
      "budget": {"type": "string", "enum": ["micro","fast","balanced","deep","full"], "default": "balanced"},
      "depth": {"type": "string", "enum": ["deterministic","ranked","analyst"], "default": "deterministic"}
    },
    "required": ["goal"]
  }
}
```

Do this for all 12 tools.

---

### 5.3 MCP Protocol Compliance

#### [MODIFY] [soma_mcp_server.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_mcp_server.py)

Ensure the stdio MCP server handles all required MCP protocol methods:
- `initialize` → return capabilities (tools)
- `initialized` → acknowledge
- `tools/list` → return all 12 tools with schemas
- `tools/call` → dispatch to `soma_*` functions, wrap result in `content[{type:"text", text:"..."}]`
- `ping` → pong
- Handle `notifications/cancelled`
- Proper JSON-RPC error codes

---

### 5.4 End-to-End Verification Script

#### [NEW] [verify_client_e2e.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/verify_client_e2e.py)

A script that:
1. Starts Soma MCP server as a subprocess
2. Sends `initialize` → verifies capabilities
3. Sends `tools/list` → verifies 12 tools with schemas
4. Calls `soma_get_map` → verifies structured response
5. Calls `soma_prepare_context` → verifies packet within budget
6. Calls `soma_ask` → verifies graph-backed answer
7. Reports pass/fail with token counts and latencies
8. Saves results to `~/.soma/acceptance/e2e_YYYYMMDD.json`

---

### Verification
```bash
# E2E test
python3 Soma/verify_client_e2e.py --project-root /Users/daliys/Daliys/Swift/Soma

# Real Gemini CLI test (after config install)
# Gemini CLI should see soma_* tools and be able to call them
```

---

## Stage 6: Production Polish & Daily Workflow

**Goal:** Everything smooth enough for actual daily AI-assisted development.

---

### 6.1 Acceptance Report System

#### [NEW] [soma_acceptance.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_acceptance.py)

- After each E2E verification, save structured report to `~/.soma/acceptance/`
- Include: tool responses, latencies, token counts, errors, graph state
- Swift app shows latest acceptance report status

---

### 6.2 Memory Governance

#### [MODIFY] [soma_mcp_server.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_mcp_server.py) — `MemoryStore`

- Add max memory items per category (50 notes, 20 known_issues, 20 patterns)
- Auto-expire entries older than 30 days
- Add `soma_remember action="search" content="query"` to find past memories
- Never store raw AI conversation text

---

### 6.3 Smart Default Project Detection

#### [MODIFY] [SomaViewModel.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/ViewModels/SomaViewModel.swift)

- On app launch, check if CWD or `SOMA_PROJECT_ROOT` is set
- Auto-detect project type and show in the header
- Remember last 6 projects with quick-switch dropdown (partially exists, polish it)

---

### 6.4 Documentation Update

#### [MODIFY] [README.md](file:///Users/daliys/Daliys/Swift/Soma/README.md)
#### [MODIFY] [GEMINI.md](file:///Users/daliys/Daliys/Swift/Soma/GEMINI.md)
#### [MODIFY] [reportD.md](file:///Users/daliys/Daliys/Swift/Soma/reportD.md)

Update all docs to reflect:
- New MCP stdio server capability
- Logging & analytics system
- Gemini CLI integration
- Updated test count and status
- New Swift UI features

---

### Verification
- Full E2E acceptance passes
- Gemini CLI can `soma_get_map` and `soma_prepare_context` on a real project
- Logs show structured entries for every call
- Swift app displays real-time activity and analytics

---

## Stage Summary

| Stage | Focus | Key Deliverable | Blocks |
|---|---|---|---|
| **1** | Fix Foundation | Green tests + working MCP stdio server | Nothing |
| **2** | Logging & Analytics | Structured JSONL logs + token tracking | Stage 1 |
| **3** | Graphify Hardening | Direct adapter, auto-refresh, richer queries | Stage 1 |
| **4** | Swift UI Overhaul | Dashboard, live activity feed, health cards | Stages 2-3 |
| **5** | AI Client Integration | Gemini/Codex config + protocol compliance + E2E | Stages 1-3 |
| **6** | Production Polish | Acceptance reports, memory governance, docs | Stages 1-5 |

> [!IMPORTANT]
> Stages 2 and 3 can run in parallel. Stage 4 depends on both. Stage 5 is the critical "go live" stage. Stage 6 is polish.

## Open Questions

1. **MCP server approach:** Keep Python as the MCP stdio server (simpler, all logic is there) or invest in native Swift MCP server (better macOS integration but significant rewrite)? **Recommendation: Keep Python.**

2. **Graphify integration:** Import `graphify` as a Python library directly, or keep it as a separate MCP server that Soma connects to as a client? The current subprocess approach is the worst of both.

3. **Which AI client first?** Codex has config mutation support but Gemini CLI is what's currently running. Should we prioritize Gemini CLI integration since it's already in use?

4. **Local model policy:** The Scout Pipeline imports `mcp` package (line 22-24 of `ScoutConfigAndConstants.py`) — is this still used? It creates a hard dependency. Should we make it optional?

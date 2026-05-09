# Graph Report - Soma  (2026-05-09)

## Corpus Check
- 67 files · ~40,138 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 968 nodes · 1795 edges · 77 communities (55 shown, 22 thin omitted)
- Extraction: 80% EXTRACTED · 20% INFERRED · 0% AMBIGUOUS · INFERRED: 365 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `f083ecce`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- [[_COMMUNITY_Model Analysis & Ranking|Model Analysis & Ranking]]
- [[_COMMUNITY_Project Discovery & Git Ops|Project Discovery & Git Ops]]
- [[_COMMUNITY_Soma Domain Models (Swift)|Soma Domain Models (Swift)]]
- [[_COMMUNITY_Go Scanner Core|Go Scanner Core]]
- [[_COMMUNITY_Soma View State & Enums|Soma View State & Enums]]
- [[_COMMUNITY_Soma ViewModel & Logic|Soma ViewModel & Logic]]
- [[_COMMUNITY_MCP Server Tests|MCP Server Tests]]
- [[_COMMUNITY_Rust Scanner & Tool Mocks|Rust Scanner & Tool Mocks]]
- [[_COMMUNITY_High-level System Concepts|High-level System Concepts]]
- [[_COMMUNITY_Scout Pipeline Tests|Scout Pipeline Tests]]
- [[_COMMUNITY_System Integration Bridge|System Integration Bridge]]
- [[_COMMUNITY_Ollama Manager (Swift)|Ollama Manager (Swift)]]
- [[_COMMUNITY_Scout Pipeline Orchestration|Scout Pipeline Orchestration]]
- [[_COMMUNITY_Live Workflow Verification|Live Workflow Verification]]
- [[_COMMUNITY_Relay State Management|Relay State Management]]
- [[_COMMUNITY_Benchmarking & Bundling|Benchmarking & Bundling]]
- [[_COMMUNITY_Go Scanner Tests|Go Scanner Tests]]
- [[_COMMUNITY_Community 17|Community 17]]
- [[_COMMUNITY_Community 18|Community 18]]
- [[_COMMUNITY_Community 19|Community 19]]
- [[_COMMUNITY_Community 20|Community 20]]
- [[_COMMUNITY_Community 21|Community 21]]
- [[_COMMUNITY_Community 22|Community 22]]
- [[_COMMUNITY_Community 23|Community 23]]
- [[_COMMUNITY_Community 24|Community 24]]
- [[_COMMUNITY_Community 25|Community 25]]
- [[_COMMUNITY_Community 26|Community 26]]
- [[_COMMUNITY_Community 27|Community 27]]
- [[_COMMUNITY_Community 28|Community 28]]
- [[_COMMUNITY_Community 29|Community 29]]
- [[_COMMUNITY_Community 30|Community 30]]
- [[_COMMUNITY_Community 31|Community 31]]
- [[_COMMUNITY_Community 32|Community 32]]
- [[_COMMUNITY_Community 33|Community 33]]
- [[_COMMUNITY_Community 34|Community 34]]
- [[_COMMUNITY_Community 35|Community 35]]
- [[_COMMUNITY_Community 36|Community 36]]
- [[_COMMUNITY_Community 37|Community 37]]
- [[_COMMUNITY_Community 38|Community 38]]
- [[_COMMUNITY_Community 39|Community 39]]
- [[_COMMUNITY_Community 40|Community 40]]
- [[_COMMUNITY_Community 41|Community 41]]
- [[_COMMUNITY_Community 42|Community 42]]
- [[_COMMUNITY_Community 43|Community 43]]
- [[_COMMUNITY_Community 44|Community 44]]
- [[_COMMUNITY_Community 45|Community 45]]
- [[_COMMUNITY_Community 46|Community 46]]
- [[_COMMUNITY_Community 47|Community 47]]
- [[_COMMUNITY_Community 48|Community 48]]
- [[_COMMUNITY_Community 49|Community 49]]
- [[_COMMUNITY_Community 50|Community 50]]
- [[_COMMUNITY_Community 51|Community 51]]
- [[_COMMUNITY_Community 52|Community 52]]
- [[_COMMUNITY_Community 53|Community 53]]
- [[_COMMUNITY_Community 54|Community 54]]
- [[_COMMUNITY_Community 55|Community 55]]
- [[_COMMUNITY_Community 56|Community 56]]
- [[_COMMUNITY_Community 57|Community 57]]
- [[_COMMUNITY_Community 61|Community 61]]
- [[_COMMUNITY_Community 62|Community 62]]
- [[_COMMUNITY_Community 63|Community 63]]
- [[_COMMUNITY_Community 64|Community 64]]
- [[_COMMUNITY_Community 65|Community 65]]
- [[_COMMUNITY_Community 67|Community 67]]
- [[_COMMUNITY_Community 68|Community 68]]
- [[_COMMUNITY_Community 69|Community 69]]
- [[_COMMUNITY_Community 70|Community 70]]
- [[_COMMUNITY_Community 71|Community 71]]
- [[_COMMUNITY_Community 72|Community 72]]
- [[_COMMUNITY_Community 73|Community 73]]
- [[_COMMUNITY_Community 74|Community 74]]
- [[_COMMUNITY_Community 75|Community 75]]
- [[_COMMUNITY_Community 76|Community 76]]

## God Nodes (most connected - your core abstractions)
1. `soma_prepare_context()` - 34 edges
2. `SomaViewModel` - 32 edges
3. `soma_prepare_context()` - 31 edges
4. `run_gather()` - 23 edges
5. `run_gather()` - 23 edges
6. `SomaMCPServerTests` - 22 edges
7. `Soma` - 20 edges
8. `soma_get_map()` - 18 edges
9. `NexusClient` - 17 edges
10. `NexusSoma Implementation Report: Etap 1-4` - 17 edges

## Surprising Connections (you probably didn't know these)
- `NexusSoma Architecture` --conceptually_related_to--> `Soma MCP Gateway Pattern`  [INFERRED]
  reportD.md → Soma/soma_mcp_server.py
- `Soma MCP Gateway Pattern` --rationale_for--> `Scout Pipeline Deterministic Compression`  [INFERRED]
  Soma/soma_mcp_server.py → reportD.md
- `Soma MCP Gateway Pattern` --references--> `Graphify Knowledge Graph`  [EXTRACTED]
  Soma/soma_mcp_server.py → GEMINI.md
- `select_evidence()` --calls--> `rel_path()`  [INFERRED]
  Soma/scout_pipeline_module/gather.py → Soma/scout_pipeline_module/utils.py
- `build_codex_packet()` --calls--> `format_line_range()`  [INFERRED]
  Soma/scout_pipeline_module/packet.py → Soma/scout_pipeline_module/parser.py

## Hyperedges (group relationships)
- **Go Scanner Subcommands** — scan_scanfiles, gitstatusfetcher_gitstatus, gitdiffparserandranker_gitdiff, text_extractsymbols, logs_taillogs [EXTRACTED 1.00]
- **Scout Pipeline Core Logic** — gatherexternelevidence_select_evidence, gatherexternelevidence_file_rank, gatherexternelevidence_build_preflight [INFERRED 0.95]
- **MCP Gateway Components** — soma_mcp_gateway, nexussoma_architecture, graphify_knowledge_graph [INFERRED 0.85]

## Communities (77 total, 22 thin omitted)

### Community 0 - "Model Analysis & Ranking"
Cohesion: 0.05
Nodes (70): CaseIterable, Codable, Equatable, Error, Hashable, Identifiable, AnalysisDepth, analyst (+62 more)

### Community 1 - "Project Discovery & Git Ops"
Cohesion: 0.1
Nodes (6): String, SomaViewModel, SomaViewModel, SomaViewModel, SomaViewModel, SomaViewModel

### Community 2 - "Soma Domain Models (Swift)"
Cohesion: 0.09
Nodes (5): LocalizedError, SomaError, ObservableObject, OllamaManager, SomaViewModel

### Community 3 - "Go Scanner Core"
Cohesion: 0.09
Nodes (27): MemoryStore, ChangedFile, runDaemon(), sendResponse(), DaemonRequest, DaemonResponse, FileItem, gitDiff() (+19 more)

### Community 4 - "Soma View State & Enums"
Cohesion: 0.06
Nodes (8): ContentView, ModelCategory, TokenCalculatorView, View, GlobalSettingsBar, LogsView, SidebarView, SystemStatusView

### Community 5 - "Soma ViewModel & Logic"
Cohesion: 0.13
Nodes (24): _compact_result(), _error_response(), _json(), NexusClient, _ok_response(), Gather debug evidence from code, git, Nexus logs, and health., Return git changes plus Unity timeline and scene delta., Write Unity code files, wait for compilation, and return compiler errors. (+16 more)

### Community 6 - "MCP Server Tests"
Cohesion: 0.07
Nodes (29): 10. Verification And Tests, 11. Current Status Snapshot, 12. Current Gaps And Risks, 13. Improvements Needed For The Feature, 14. Recommended Next Etap, 15. Key Files, 16. Final Assessment, 1. Executive Summary (+21 more)

### Community 7 - "Rust Scanner & Tool Mocks"
Cohesion: 0.13
Nodes (23): min(), classify_prompt_intent(), packet_mode_for_prompt(), extract_symbols(), categorize_path(), dedupe_strings(), is_noise_path(), parse_recent_roots() (+15 more)

### Community 8 - "High-level System Concepts"
Cohesion: 0.14
Nodes (26): build_codex_packet(), build_enriched_prompt(), build_omitted_context(), bundle_for_direct_pass(), estimate_tokens(), indent_block(), prompt_terms(), build_repo_index() (+18 more)

### Community 9 - "Scout Pipeline Tests"
Cohesion: 0.14
Nodes (24): _compact_result(), _error_response(), _json(), _ok_response(), _safe_nexus_result(), _safe_text(), Save, list, or clear structured project memory., soma_remember() (+16 more)

### Community 10 - "System Integration Bridge"
Cohesion: 0.15
Nodes (23): _analysis_depth(), _append_graph_context(), _enforce_packet_budget(), _evidence_summary(), _packet_budget(), detect_project_type(), iter_project_files(), format_git_diff_summary() (+15 more)

### Community 11 - "Ollama Manager (Swift)"
Cohesion: 0.14
Nodes (4): NexusClient, NexusState, _parse_ports(), GraphifyAdapter

### Community 13 - "Live Workflow Verification"
Cohesion: 0.14
Nodes (11): GoDaemon, build_go_scanner(), build_repo_index(), cache_key_for_root(), file_digest(), index_cache_path(), build_rust_scanner(), extract_unity_refs() (+3 more)

### Community 14 - "Relay State Management"
Cohesion: 0.18
Nodes (19): normalize_path(), _backup_path(), build_client_config(), build_status_payload(), _codex_backup_candidates(), codex_config_default_path(), _count_toml_table(), discover_nexus() (+11 more)

### Community 15 - "Benchmarking & Bundling"
Cohesion: 0.15
Nodes (9): extract_unity_refs(), main(), args(), FakeSession, FakeText, FakeTool, FakeToolResult, FakeToolsResult (+1 more)

### Community 16 - "Go Scanner Tests"
Cohesion: 0.18
Nodes (9): find_graph_json(), get_memory_dir(), GraphifyAdapter, load_memory(), MemoryStore, query_graph_simple(), Save, list, or clear structured project memory., save_memory() (+1 more)

### Community 17 - "Community 17"
Cohesion: 0.15
Nodes (18): _estimate_tokens(), log_mcp_event(), log_mcp_request(), log_mcp_response(), log_server_start(), log_server_stop(), log_tool_call(), Decorator for soma_* async functions.     Measures latency, estimates token coun (+10 more)

### Community 18 - "Community 18"
Cohesion: 0.19
Nodes (16): classify_prompt_intent(), packet_mode_for_prompt(), prompt_terms(), build_preflight(), build_reason(), evidence_item_from_path(), file_rank(), select_evidence() (+8 more)

### Community 19 - "Community 19"
Cohesion: 0.16
Nodes (17): analyze_packet_with_model(), fallback_summary(), format_model_analysis(), format_preflight(), rank_evidence_with_model(), ranker_payload(), should_use_model_summary(), summarize_with_ollama() (+9 more)

### Community 20 - "Community 20"
Cohesion: 0.18
Nodes (16): content_str(), extract_tool_calls(), get_ollama_tools(), get_server_params(), query_ollama(), query_ollama_model(), run_chat(), extract_json_object() (+8 more)

### Community 21 - "Community 21"
Cohesion: 0.21
Nodes (11): _backup_path(), build_client_config(), _codex_backup_candidates(), codex_config_default_path(), _count_toml_table(), install_codex_config(), main(), _remove_toml_table_block() (+3 more)

### Community 22 - "Community 22"
Cohesion: 0.12
Nodes (15): Benchmarking, code:text (Big AI client), code:text (/Users/daliys/Daliys/Swift/Soma/reportD.md), code:bash (cd /Users/daliys/Daliys/Swift/Soma), code:text (Deterministic first.), Current Limitations, Current Status, License (+7 more)

### Community 23 - "Community 23"
Cohesion: 0.13
Nodes (14): code:text (Big AI clients should connect to Soma only.), code:bash (cd /Users/daliys/Daliys/Swift/Soma), code:text (Ran 31 tests), code:bash (cd /Users/daliys/Daliys/Swift/Soma), Codex Config State, Current Architecture, Current Workflow, Development Rules (+6 more)

### Community 24 - "Community 24"
Cohesion: 0.22
Nodes (12): get_active_project_root(), build_status_payload(), _server_script_path(), extract_explicit_paths(), gather_external_evidence(), categorize_path(), dedupe_strings(), fix_path() (+4 more)

### Community 25 - "Community 25"
Cohesion: 0.14
Nodes (14): Soma Content View, Graphify Knowledge Graph, NexusSoma Architecture, Ollama Local Models, Evidence Relay, Scout Pipeline Deterministic Compression, Scout Pipeline, Local-First Evidence Compiler (+6 more)

### Community 27 - "Community 27"
Cohesion: 0.21
Nodes (13): runDaemon, gitDiff, gitStatus, GlobalSettingsBar, tailLogs, main, OllamaManager, Soma Local-First Evidence Compiler (+5 more)

### Community 28 - "Community 28"
Cohesion: 0.17
Nodes (12): 6.1 Acceptance Report System, 6.2 Memory Governance, 6.3 Smart Default Project Detection, 6.4 Documentation Update, [MODIFY] [GEMINI.md](file:///Users/daliys/Daliys/Swift/Soma/GEMINI.md), [MODIFY] [README.md](file:///Users/daliys/Daliys/Swift/Soma/README.md), [MODIFY] [reportD.md](file:///Users/daliys/Daliys/Swift/Soma/reportD.md), [MODIFY] [soma_mcp_server.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_mcp_server.py) — `MemoryStore` (+4 more)

### Community 29 - "Community 29"
Cohesion: 0.18
Nodes (11): 2.1 Python Structured Logger, 2.2 Token Analytics Dashboard Data, 2.3 Swift Log Viewer, [MODIFY] [SidebarView.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/Views/SidebarView.swift), [MODIFY] [soma_mcp_server.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_mcp_server.py), [MODIFY] [SomaViewModel.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/ViewModels/SomaViewModel.swift), [NEW] [LogsView.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/Views/LogsView.swift), [NEW] [soma_analytics.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_analytics.py) (+3 more)

### Community 30 - "Community 30"
Cohesion: 0.2
Nodes (11): build_codex_packet, classify_prompt_intent, build_repo_index, extract_symbols, extract_unity_refs, get_git_status, soma_scanner, GoDaemon (+3 more)

### Community 31 - "Community 31"
Cohesion: 0.38
Nodes (9): _call_compact(), _compact_payload(), _content_text(), _find_instance_id(), _json_payload(), main(), run(), _server_script() (+1 more)

### Community 32 - "Community 32"
Cohesion: 0.2
Nodes (10): 1.1 Fix Failing Tests, 1.2 Restore Python MCP Stdio Server, 1.3 Update Swift Server Launch, code:bash (# Tests must pass), [MODIFY] [soma_mcp_server.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_mcp_server.py), [MODIFY] [SomaMCPCoordinator.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/SomaMCPCoordinator.swift), [MODIFY] [SomaViewModel.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/ViewModels/SomaViewModel.swift), [MODIFY] [test_scout_pipeline.py](file:///Users/daliys/Daliys/Swift/Soma/tests/test_scout_pipeline.py) (+2 more)

### Community 33 - "Community 33"
Cohesion: 0.2
Nodes (10): 5.2 Tool Schema Compliance, 5.3 MCP Protocol Compliance, 5.4 End-to-End Verification Script, code:python ({), code:bash (# E2E test), [MODIFY] [soma_mcp_server.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_mcp_server.py), [MODIFY] [soma_mcp_server.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_mcp_server.py), [NEW] [verify_client_e2e.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/verify_client_e2e.py) (+2 more)

### Community 34 - "Community 34"
Cohesion: 0.22
Nodes (9): CLI Usage, code:bash (cd /Users/daliys/Daliys/Swift/Soma), code:bash (/opt/homebrew/bin/python3 Soma/soma_mcp_server.py \), code:text (codex), code:bash (/opt/homebrew/bin/python3 Soma/verify_soma_live_workflow.py ), code:bash (/opt/homebrew/bin/python3 Soma/verify_soma_live_workflow.py ), Live Verifier, Print Client Config (+1 more)

### Community 35 - "Community 35"
Cohesion: 0.22
Nodes (9): 4.1 MCP Gateway Dashboard, 4.2 Real-Time Activity Feed, 4.3 Project Health Card, [MODIFY] [ContentView.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/ContentView.swift), [MODIFY] [GlobalSettingsBar.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/Views/GlobalSettingsBar.swift), [MODIFY] [SidebarView.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/Views/SidebarView.swift), [NEW] [MCPDashboardView.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/Views/MCPDashboardView.swift), Stage 4: Swift UI Overhaul for Observability (+1 more)

### Community 36 - "Community 36"
Cohesion: 0.25
Nodes (8): 3.1 Graphify MCP Adapter, 3.2 Auto-Refresh Graph on Project Change, 3.3 Enrich `soma_ask` with Deep Graph Queries, [MODIFY] [soma_mcp_server.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_mcp_server.py) — `GraphifyAdapter`, [MODIFY] [soma_mcp_server.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_mcp_server.py) — `soma_ask()`, [MODIFY] [SomaViewModel.swift](file:///Users/daliys/Daliys/Swift/Soma/Soma/ViewModels/SomaViewModel.swift), Stage 3: Graphify Integration Hardening, Verification

### Community 37 - "Community 37"
Cohesion: 0.29
Nodes (6): Current State Assessment, Open Questions, Soma: Master Implementation Plan — From Prototype to Production, Stage Summary, What's Broken / Missing, What Works

### Community 40 - "Community 40"
Cohesion: 0.6
Nodes (5): benchmark(), build_trimmed_bundle(), main(), ollama_chat(), run_gather()

### Community 42 - "Community 42"
Cohesion: 0.47
Nodes (4): compute_multiday_summary(), compute_report(), Aggregate stats across the last N days., _read_entries()

### Community 44 - "Community 44"
Cohesion: 0.4
Nodes (5): code:bash (cd /Users/daliys/Daliys/Swift/Soma), code:text (Ran 31 tests), code:bash (PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 -m py_co), code:bash (cd /Users/daliys/Daliys/Swift/Soma), Testing

### Community 45 - "Community 45"
Cohesion: 0.4
Nodes (5): code:text (deterministic only), code:text (preflight -> deterministic -> optional ranker -> optional an), code:text (SOMA_LOCAL_MODEL=gemma4:e4b), code:bash (OLLAMA_CONTEXT_LENGTH=4096 \), Local Model Policy

### Community 46 - "Community 46"
Cohesion: 0.83
Nodes (3): collect_files_used(), query_ollama(), relay()

### Community 47 - "Community 47"
Cohesion: 0.5
Nodes (4): code:bash (/opt/homebrew/bin/python3 Soma/soma_mcp_server.py \), code:bash (/opt/homebrew/bin/python3 Soma/soma_mcp_server.py \), code:bash (/opt/homebrew/bin/python3 Soma/soma_mcp_server.py \), Install, Verify, Roll Back Codex Config

### Community 48 - "Community 48"
Cohesion: 0.5
Nodes (4): Architecture, code:mermaid (flowchart TD), How Soma and Nexus Work Together, Main Components

### Community 49 - "Community 49"
Cohesion: 0.5
Nodes (4): Long Term, Medium Term, Near Term, Roadmap

### Community 50 - "Community 50"
Cohesion: 0.5
Nodes (4): code:text (graphify-out/graph.json), code:text (/Users/daliys/Daliys/UnityProjects/UnityTestForNexus/graphif), code:text (/Users/daliys/Daliys/Swift/Soma/graphify-out/graph.json), Graphify

### Community 51 - "Community 51"
Cohesion: 0.5
Nodes (4): code:bash (PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 Soma/sco), code:bash (SOMA_LOCAL_MODEL=gemma4:e4b \), code:bash (SOMA_LOCAL_MODEL=gemma4:e4b \), Direct Scout Pipeline

### Community 52 - "Community 52"
Cohesion: 0.5
Nodes (4): 5.1 Gemini CLI Config, code:json ({), [MODIFY] MCP Config Installation, [MODIFY] [soma_mcp_server.py](file:///Users/daliys/Daliys/Swift/Soma/Soma/soma_mcp_server.py)

### Community 54 - "Community 54"
Cohesion: 0.67
Nodes (3): code:bash (open /Users/daliys/Daliys/Swift/Soma/Soma.xcodeproj), code:text (/Users/daliys/Daliys/UnityProjects/UnityTestForNexus), Swift App Workflow

### Community 55 - "Community 55"
Cohesion: 0.67
Nodes (3): code:text (Use local deterministic tools first.), code:text (Use the Soma packet first.), Why Soma Exists

### Community 56 - "Community 56"
Cohesion: 0.67
Nodes (3): OllamaManager, SidebarView, SomaViewModel

### Community 57 - "Community 57"
Cohesion: 0.67
Nodes (3): is_noise_path, normalize_path, build_preflight

## Knowledge Gaps
- **214 isolated node(s):** `Rough 4-chars-per-token estimate.`, `Remove JSONL logs older than SOMA_LOG_RETENTION_DAYS.`, `Append a structured log entry to today's JSONL file (fire-and-forget).`, `Write a single structured log entry.`, `Decorator for soma_* async functions.     Measures latency, estimates token coun` (+209 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **22 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `gitDiff()` connect `Go Scanner Core` to `Go Scanner Tests`, `Project Discovery & Git Ops`?**
  _High betweenness centrality (0.097) - this node is a cross-community bridge._
- **Why does `min()` connect `Rust Scanner & Tool Mocks` to `Go Scanner Core`, `System Integration Bridge`, `Community 18`, `Community 19`, `Community 20`?**
  _High betweenness centrality (0.082) - this node is a cross-community bridge._
- **Why does `soma_prepare_context()` connect `High-level System Concepts` to `Soma ViewModel & Logic`, `Rust Scanner & Tool Mocks`, `Relay State Management`, `Go Scanner Tests`, `Community 19`?**
  _High betweenness centrality (0.066) - this node is a cross-community bridge._
- **Are the 19 inferred relationships involving `soma_prepare_context()` (e.g. with `normalize_path()` and `classify_prompt_intent()`) actually correct?**
  _`soma_prepare_context()` has 19 INFERRED edges - model-reasoned connections that need verification._
- **Are the 29 inferred relationships involving `soma_prepare_context()` (e.g. with `soma_debug()` and `soma_review()`) actually correct?**
  _`soma_prepare_context()` has 29 INFERRED edges - model-reasoned connections that need verification._
- **What connects `Rough 4-chars-per-token estimate.`, `Remove JSONL logs older than SOMA_LOG_RETENTION_DAYS.`, `Append a structured log entry to today's JSONL file (fire-and-forget).` to the rest of the system?**
  _214 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Model Analysis & Ranking` be split into smaller, more focused modules?**
  _Cohesion score 0.05 - nodes in this community are weakly interconnected._
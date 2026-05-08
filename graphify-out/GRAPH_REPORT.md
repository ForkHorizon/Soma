# Graph Report - .  (2026-05-08)

## Corpus Check
- Corpus is ~39,822 words - fits in a single context window. You may not need a graph.

## Summary
- 488 nodes · 962 edges · 37 communities (17 shown, 20 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 148 edges (avg confidence: 0.81)
- Token cost: 0 input · 0 output

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

## God Nodes (most connected - your core abstractions)
1. `soma_prepare_context()` - 34 edges
2. `SomaViewModel` - 32 edges
3. `run_gather()` - 23 edges
4. `SomaMCPServerTests` - 22 edges
5. `soma_get_map()` - 18 edges
6. `soma_code_context()` - 17 edges
7. `NexusClient` - 15 edges
8. `soma_delta()` - 14 edges
9. `ContentView` - 14 edges
10. `build_preflight()` - 14 edges

## Surprising Connections (you probably didn't know these)
- `NexusSoma Architecture` --conceptually_related_to--> `Soma MCP Gateway Pattern`  [INFERRED]
  reportD.md → Soma/soma_mcp_server.py
- `Soma MCP Gateway Pattern` --rationale_for--> `Scout Pipeline Deterministic Compression`  [INFERRED]
  Soma/soma_mcp_server.py → reportD.md
- `Soma MCP Gateway Pattern` --references--> `Graphify Knowledge Graph`  [EXTRACTED]
  Soma/soma_mcp_server.py → GEMINI.md
- `Soma MCP Server Tests` --calls--> `Soma MCP Server`  [EXTRACTED]
  tests/test_soma_mcp_server.py → Soma/soma_mcp_server.py
- `Scout Pipeline Deterministic Compression` --conceptually_related_to--> `Ollama Local Models`  [INFERRED]
  reportD.md → ollama_logs.txt

## Hyperedges (group relationships)
- **Go Scanner Subcommands** — scan_scanfiles, gitstatusfetcher_gitstatus, gitdiffparserandranker_gitdiff, text_extractsymbols, logs_taillogs [EXTRACTED 1.00]
- **Scout Pipeline Core Logic** — gatherexternelevidence_select_evidence, gatherexternelevidence_file_rank, gatherexternelevidence_build_preflight [INFERRED 0.95]
- **MCP Gateway Components** — soma_mcp_gateway, nexussoma_architecture, graphify_knowledge_graph [INFERRED 0.85]

## Communities (37 total, 20 thin omitted)

### Community 0 - "Model Analysis & Ranking"
Cohesion: 0.05
Nodes (67): min(), analyze_packet_with_model(), fallback_summary(), format_model_analysis(), format_preflight(), rank_evidence_with_model(), ranker_payload(), should_use_model_summary() (+59 more)

### Community 1 - "Project Discovery & Git Ops"
Cohesion: 0.07
Nodes (52): detect_project_type(), get_git_diff_summary(), get_git_status(), _backup_path(), build_status_payload(), _codex_backup_candidates(), codex_config_default_path(), _compact_result() (+44 more)

### Community 2 - "Soma Domain Models (Swift)"
Cohesion: 0.1
Nodes (33): Codable, Error, Hashable, ClientConfigInstallStatus, ClientConfigRollbackStatus, ClientConfigStatus, LiveVerifyCall, LiveVerifyStatus (+25 more)

### Community 3 - "Go Scanner Core"
Cohesion: 0.09
Nodes (29): ChangedFile, runDaemon(), sendResponse(), DaemonRequest, DaemonResponse, FileItem, gitDiff(), rankDiffHunks() (+21 more)

### Community 4 - "Soma View State & Enums"
Cohesion: 0.07
Nodes (17): CaseIterable, Identifiable, AnalysisDepth, analyst, deterministic, ranked, AppMode, relay (+9 more)

### Community 5 - "Soma ViewModel & Logic"
Cohesion: 0.13
Nodes (3): LocalizedError, SomaError, SomaViewModel

### Community 7 - "Rust Scanner & Tool Mocks"
Cohesion: 0.15
Nodes (9): extract_unity_refs(), main(), args(), FakeSession, FakeText, FakeTool, FakeToolResult, FakeToolsResult (+1 more)

### Community 8 - "High-level System Concepts"
Cohesion: 0.14
Nodes (14): Soma Content View, Graphify Knowledge Graph, NexusSoma Architecture, Ollama Local Models, Evidence Relay, Scout Pipeline Deterministic Compression, Scout Pipeline, Local-First Evidence Compiler (+6 more)

### Community 10 - "System Integration Bridge"
Cohesion: 0.21
Nodes (13): runDaemon, gitDiff, gitStatus, GlobalSettingsBar, tailLogs, main, OllamaManager, Soma Local-First Evidence Compiler (+5 more)

### Community 12 - "Scout Pipeline Orchestration"
Cohesion: 0.2
Nodes (11): build_codex_packet, classify_prompt_intent, build_repo_index, extract_symbols, extract_unity_refs, get_git_status, soma_scanner, GoDaemon (+3 more)

### Community 13 - "Live Workflow Verification"
Cohesion: 0.38
Nodes (9): _call_compact(), _compact_payload(), _content_text(), _find_instance_id(), _json_payload(), main(), run(), _server_script() (+1 more)

### Community 14 - "Relay State Management"
Cohesion: 0.29
Nodes (7): Equatable, RelayPhase, done, failed, gathering, idle, relaying

### Community 15 - "Benchmarking & Bundling"
Cohesion: 0.6
Nodes (5): benchmark(), build_trimmed_bundle(), main(), ollama_chat(), run_gather()

### Community 17 - "Community 17"
Cohesion: 0.83
Nodes (3): collect_files_used(), query_ollama(), relay()

### Community 19 - "Community 19"
Cohesion: 0.67
Nodes (3): OllamaManager, SidebarView, SomaViewModel

### Community 20 - "Community 20"
Cohesion: 0.67
Nodes (3): is_noise_path, normalize_path, build_preflight

## Knowledge Gaps
- **74 isolated node(s):** `invalidRequest`, `Compile a bounded evidence packet for implementation, debug, or review work.`, `Return a compact living project map from git, Graphify, Nexus, and memory.`, `Answer a project question with Graphify context.`, `Inspect a Unity object or component through filtered Nexus calls.` (+69 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **20 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `soma_prepare_context()` connect `Model Analysis & Ranking` to `Project Discovery & Git Ops`, `Go Scanner Core`?**
  _High betweenness centrality (0.064) - this node is a cross-community bridge._
- **Why does `SomaViewModel` connect `Soma ViewModel & Logic` to `Ollama Manager (Swift)`?**
  _High betweenness centrality (0.028) - this node is a cross-community bridge._
- **Why does `SomaError` connect `Soma ViewModel & Logic` to `Soma Domain Models (Swift)`?**
  _High betweenness centrality (0.026) - this node is a cross-community bridge._
- **Are the 19 inferred relationships involving `soma_prepare_context()` (e.g. with `normalize_path()` and `classify_prompt_intent()`) actually correct?**
  _`soma_prepare_context()` has 19 INFERRED edges - model-reasoned connections that need verification._
- **Are the 22 inferred relationships involving `run_gather()` (e.g. with `classify_prompt_intent()` and `parse_recent_roots()`) actually correct?**
  _`run_gather()` has 22 INFERRED edges - model-reasoned connections that need verification._
- **What connects `invalidRequest`, `Compile a bounded evidence packet for implementation, debug, or review work.`, `Return a compact living project map from git, Graphify, Nexus, and memory.` to the rest of the system?**
  _74 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Model Analysis & Ranking` be split into smaller, more focused modules?**
  _Cohesion score 0.05 - nodes in this community are weakly interconnected._
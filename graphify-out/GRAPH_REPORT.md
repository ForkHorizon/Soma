# Graph Report - .  (2026-05-04)

## Corpus Check
- Corpus is ~15,989 words - fits in a single context window. You may not need a graph.

## Summary
- 187 nodes · 386 edges · 17 communities detected
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 2 edges (avg confidence: 0.9)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Core Data Models (Swift)|Core Data Models (Swift)]]
- [[_COMMUNITY_View Model & State Management|View Model & State Management]]
- [[_COMMUNITY_Scout Pipeline Rationale & Tests|Scout Pipeline Rationale & Tests]]
- [[_COMMUNITY_SwiftUI Views & Components|SwiftUI Views & Components]]
- [[_COMMUNITY_Scout Pipeline Intent & Preflight|Scout Pipeline Intent & Preflight]]
- [[_COMMUNITY_Scout Pipeline Packet Building & Ollama Integration|Scout Pipeline Packet Building & Ollama Integration]]
- [[_COMMUNITY_Scout Pipeline Indexing & Utility|Scout Pipeline Indexing & Utility]]
- [[_COMMUNITY_Ollama Management (Swift)|Ollama Management (Swift)]]
- [[_COMMUNITY_Scout Pipeline File Gathering & Git Analysis|Scout Pipeline File Gathering & Git Analysis]]
- [[_COMMUNITY_Scout Pipeline Model Analysis & Querying|Scout Pipeline Model Analysis & Querying]]
- [[_COMMUNITY_Relay Phase Enums|Relay Phase Enums]]
- [[_COMMUNITY_Ollama Benchmarking (Python)|Ollama Benchmarking (Python)]]
- [[_COMMUNITY_Relay Script (Python)|Relay Script (Python)]]
- [[_COMMUNITY_App Lifecycle (Swift)|App Lifecycle (Swift)]]
- [[_COMMUNITY_External Tooling (Ollama, Codex, Unity)|External Tooling (Ollama, Codex, Unity)]]
- [[_COMMUNITY_Backend Workers (Mojo, Python, Swift)|Backend Workers (Mojo, Python, Swift)]]
- [[_COMMUNITY_System Integrations (Git, Unity)|System Integrations (Git, Unity)]]

## God Nodes (most connected - your core abstractions)
1. `run_gather()` - 23 edges
2. `SomaViewModel` - 19 edges
3. `ContentView` - 18 edges
4. `ScoutPipelineTests` - 12 edges
5. `build_preflight()` - 10 edges
6. `build_codex_packet()` - 10 edges
7. `OllamaManager` - 10 edges
8. `select_evidence()` - 9 edges
9. `normalize_path()` - 8 edges
10. `build_repo_index()` - 8 edges

## Surprising Connections (you probably didn't know these)
- `local_junior.prepare_context` --references--> `Git Integration`  [INFERRED]
  Prompt.txt → README.md
- `local_junior.prepare_context` --references--> `Unity YAML Parsing`  [INFERRED]
  Prompt.txt → README.md
- `local-junior-mcp` --references--> `Ollama`  [EXTRACTED]
  Prompt.txt → ollama_final.txt

## Communities

### Community 0 - "Core Data Models (Swift)"
Cohesion: 0.17
Nodes (24): CaseIterable, Codable, Hashable, Identifiable, Sendable, AnalysisDepth, analyst, deterministic (+16 more)

### Community 1 - "View Model & State Management"
Cohesion: 0.21
Nodes (4): LocalizedError, SomaError, SomaViewModel, String

### Community 2 - "Scout Pipeline Rationale & Tests"
Cohesion: 0.18
Nodes (9): Codex, Deterministic Preflight, gemma4:e4b, qwen3-coder:30b-a3b-q4_K_M, Ranked Evidence Packet, Scout Pipeline, Soma, ScoutPipelineTests (+1 more)

### Community 3 - "SwiftUI Views & Components"
Cohesion: 0.18
Nodes (2): ContentView, View

### Community 4 - "Scout Pipeline Intent & Preflight"
Cohesion: 0.2
Nodes (15): build_preflight(), build_reason(), bundle_for_direct_pass(), classify_prompt_intent(), detect_project_type(), estimate_tokens(), excerpt_for_log(), fallback_summary() (+7 more)

### Community 5 - "Scout Pipeline Packet Building & Ollama Integration"
Cohesion: 0.25
Nodes (14): build_codex_packet(), build_enriched_prompt(), build_omitted_context(), content_str(), extract_tool_calls(), fix_path(), format_git_diff_summary(), format_line_range() (+6 more)

### Community 6 - "Scout Pipeline Indexing & Utility"
Cohesion: 0.22
Nodes (13): build_repo_index(), cache_key_for_root(), dedupe_strings(), evidence_item_from_path(), excerpt_for_text(), extract_symbols(), extract_unity_refs(), file_digest() (+5 more)

### Community 7 - "Ollama Management (Swift)"
Cohesion: 0.35
Nodes (2): ObservableObject, OllamaManager

### Community 8 - "Scout Pipeline File Gathering & Git Analysis"
Cohesion: 0.22
Nodes (10): categorize_path(), extract_explicit_paths(), gather_external_evidence(), get_git_diff_summary(), get_git_status(), is_noise_path(), iter_project_files(), rank_diff_hunks() (+2 more)

### Community 9 - "Scout Pipeline Model Analysis & Querying"
Cohesion: 0.38
Nodes (7): analyze_packet_with_model(), extract_json_object(), query_ollama(), query_ollama_model(), rank_evidence_with_model(), ranker_payload(), summarize_with_ollama()

### Community 10 - "Relay Phase Enums"
Cohesion: 0.29
Nodes (7): Equatable, RelayPhase, done, failed, gathering, idle, relaying

### Community 11 - "Ollama Benchmarking (Python)"
Cohesion: 0.6
Nodes (5): benchmark(), build_trimmed_bundle(), main(), ollama_chat(), run_gather()

### Community 12 - "Relay Script (Python)"
Cohesion: 0.83
Nodes (3): collect_files_used(), query_ollama(), relay()

### Community 13 - "App Lifecycle (Swift)"
Cohesion: 0.67
Nodes (2): App, SomaApp

### Community 14 - "External Tooling (Ollama, Codex, Unity)"
Cohesion: 0.67
Nodes (3): local-junior-mcp, Ollama, Unity

### Community 15 - "Backend Workers (Mojo, Python, Swift)"
Cohesion: 0.67
Nodes (3): Mojo Worker, Python Worker, Swift MCP Server

### Community 16 - "System Integrations (Git, Unity)"
Cohesion: 0.67
Nodes (3): Git Integration, local_junior.prepare_context, Unity YAML Parsing

## Knowledge Gaps
- **22 isolated node(s):** `scout`, `relay`, `deterministic`, `ranked`, `analyst` (+17 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **Thin community `SwiftUI Views & Components`** (17 nodes): `ContentView`, `.answerPanel()`, `.badge()`, `.bundlePanel()`, `.chooseProjectRoot()`, `.copyToClipboard()`, `.diffSummaryView()`, `.emptyState()`, `.evidenceRow()`, `.inputBar()`, `.labeledBlock()`, `.phaseCard()`, `.recentRootButton()`, `.repoIndexSummary()`, `.shortPath()`, `.stageSummary()`, `View`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Ollama Management (Swift)`** (11 nodes): `ObservableObject`, `.ollamaAction()`, `OllamaManager`, `.checkStatus()`, `.init()`, `.launchOllama()`, `.sendKeepAlive()`, `.startModel()`, `.startPolling()`, `.stopModel()`, `.updateStatus()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `App Lifecycle (Swift)`** (3 nodes): `App`, `SomaApp`, `SomaApp.swift`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `ContentView` connect `SwiftUI Views & Components` to `Core Data Models (Swift)`, `Ollama Management (Swift)`?**
  _High betweenness centrality (0.058) - this node is a cross-community bridge._
- **Why does `SomaViewModel` connect `View Model & State Management` to `Core Data Models (Swift)`, `Ollama Management (Swift)`?**
  _High betweenness centrality (0.046) - this node is a cross-community bridge._
- **Why does `RelayPhase` connect `Relay Phase Enums` to `Core Data Models (Swift)`?**
  _High betweenness centrality (0.028) - this node is a cross-community bridge._
- **What connects `scout`, `relay`, `deterministic` to the rest of the system?**
  _22 weakly-connected nodes found - possible documentation gaps or missing edges._
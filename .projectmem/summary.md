# projectmem - Soma

_Last updated: 2026-07-08_

## Project purpose
Replace this placeholder with a concise description of what this project does, who it serves, and the main technologies or runtime assumptions.

## Recent issues
- [DONE] #legacy_f869 Legacy issue: Refactor: Resolve retain cycles in ViewModels using `[weak self]` in `Task` closures -> Refactor: Resolve retain cycles in ViewModels using `[weak self]` in `Task` closures (fixed)
- [DONE] #legacy_d74b Legacy issue: Merge pull request #40 from Daliys/fix/soma-language-optimizer-placeholder-hallucination-4174225553131885396 -> Merge pull request #40 from Daliys/fix/soma-language-optimizer-placeholder-hallucination-4174225553131885396 (fixed)
- [DONE] #legacy_d42e Legacy issue: Merge pull request #42 from Daliys/fix-regex-edge-cases-6582744517876628760 -> Merge pull request #42 from Daliys/fix-regex-edge-cases-6582744517876628760 (fixed)
- [DONE] #legacy_adae Legacy issue: Fix edge cases in language optimizer regexes for nested JSON, closures, and chained shell commands -> Fix edge cases in language optimizer regexes for nested JSON, closures, and chained shell commands (fixed)
- [DONE] #legacy_a38c Legacy issue: Refactor: Resolve retain cycles in ViewModels using `[weak self]` in `Task` closures -> Refactor: Resolve retain cycles in ViewModels using `[weak self]` in `Task` closures (fixed)
- [DONE] #legacy_77d4 Legacy issue: Fix LLM hallucinated placeholder corruption in prompt optimization -> Fix LLM hallucinated placeholder corruption in prompt optimization (fixed)
- [DONE] #legacy_61cb Legacy issue: ⚡ Bolt: MainActor UI freeze fixes via async/Task offloading (#39) -> ⚡ Bolt: MainActor UI freeze fixes via async/Task offloading (#39) (fixed)
- [DONE] #legacy_5a61 Legacy issue: Fix LLM hallucinated placeholder corruption in prompt optimization -> Fix LLM hallucinated placeholder corruption in prompt optimization (fixed)
- [DONE] #legacy_514b Legacy issue: Refactor: Resolve retain cycles in ViewModels using `[weak self]` in `Task` closures -> Refactor: Resolve retain cycles in ViewModels using `[weak self]` in `Task` closures (fixed)
- [DONE] #legacy_4344 Legacy issue: Fix indefinite UI hangs on Python crashes (#43) -> Fix indefinite UI hangs on Python crashes (#43) (fixed)
- [DONE] #legacy_32b0 Legacy issue: Merge pull request #44 from Daliys/fix/swift-viewmodel-memory-leaks-8864650526849477251 -> Merge pull request #44 from Daliys/fix/swift-viewmodel-memory-leaks-8864650526849477251 (fixed)
- [DONE] #0010 Soma writes always-on memory tool instructions into projects, causing token-heavy projectmem/codebase-memory use on small tasks. [Soma/extension_manager.py] -> Soma now writes light, per-tool memory instructions so new projects do not force token-heavy memory usage for small tasks. [Soma/extension_manager.py; AGENTS.md; tests/test_soma_mcp_server.py] (fixed)
- [DONE] #0009 Project tool chooser shows Install for tools already installed in the selected project instead of an Installed state. [Soma/ContentView.swift] -> Project Add Tool chooser now marks selected-project tools as Installed and only shows Install for missing supported tools. [Soma/ContentView.swift] (fixed)
- [DONE] #0008 Project Overview Add Tool runs a fixed memory setup action instead of opening a panel to choose which extension tool to install. [Soma/ContentView.swift] -> Add Tool now opens a project tool chooser and installs the selected supported tool with visible progress/result feedback. [Soma/ContentView.swift; Soma/gateway/server_cli.py; Soma/extension_manager.py; tests/test_soma_mcp_server.py] (fixed)
- [DONE] #0007 Project Overview still renders old project cards during the first render after switching projects because the UI reads stale overview state directly. [Soma/ContentView.swift] -> Project Overview now hides stale project cards behind skeleton placeholders until the selected project's payload arrives; xcodebuild passes. [Soma/ContentView.swift] (fixed)
- [DONE] #0006 Project Overview keeps showing the previous project's cards while the new selected project's async refresh is still running. [Soma/ContentView.swift] -> Project Overview now clears stale cards immediately on project switch and only applies helper results for the still-selected project; xcodebuild passes. [Soma/ContentView.swift] (fixed)
- [DONE] #0005 Project Overview Memory card still shows possible memory tools as missing rows instead of only installed project tools with an add-tool action. [Soma/ContentView.swift] -> Project Overview Memory card now lists only installed tools for the selected project and exposes Add Tool using the existing setup-memory extension path; Python tests and macOS build pass. [Soma/ContentView.swift] (fixed)
- [DONE] #0004 The main Soma window hides the standard macOS close, minimize, and fullscreen traffic-light controls. [Soma/ContentView.swift] -> Main Soma window no longer hides the window toolbar, so macOS close/minimize/fullscreen controls can render; verified with xcodebuild. [Soma/ContentView.swift] (fixed)
- [DONE] #0003 Project Overview shows global Other Project Alerts and scans unrelated projects instead of staying scoped to the selected root. [Soma/ContentView.swift] -> Project Overview is now selected-project scoped: no Other Project Alerts, no global plugin card, and project client sync touches only selected local configs. [Soma/ContentView.swift] (fixed)
- [DONE] #0002 Selecting an existing project in the sidebar reorders recentProjectRoots and moves the clicked project to the top. [Soma/ViewModels/SomaViewModel+Project.swift] -> Project clicks no longer move items to the top; existing sidebar order is preserved and macOS build passes. [Soma/ViewModels/SomaViewModel+Project.swift] (fixed)
- [DONE] #0001 Clicking a project in the Projects sidebar only selects the root and does not open a useful project detail view. [Soma/Views/SidebarView.swift] -> Project sidebar clicks now open a Project Overview with Git, memory, graph, plugin, and AI-client status; verified with Python tests and macOS build. [Soma/Views/SidebarView.swift] (fixed)

## Decisions
- Project sidebar clicks should open a main-detail Project Overview route; setup, client sync, and graph refresh remain explicit button actions, not automatic on click. [Soma/Views/SidebarView.swift]
- Project Overview is strictly selected-project scoped; cross-project alerts and broad project scanning do not belong in this view. [Soma/ContentView.swift]
- Memory tool docs generated by Soma default to light mode: use projectmem/codebase-memory only for larger, uncertain, historical, or structural work, not small obvious edits. [Soma/extension_manager.py]

## Notes
- Rus to Prompt
- Merge pull request #37 from Daliys/saving
- feat: implement strict circuit breaker and robust prompt repair retries
- Merge pull request #41 from Daliys/robust-optimizer-circuit-breaker-11704795935277478985
- added explicit signature metadata for every Soma tool
- Add DeepSeek provider integration
- Cleanup: remove evidence-compiler UI (Prepare Packet, packets, projects, diagnostics, scout)
- docs: reframe SOMA as local model bench + per-project control panel
- Improve Soma extension updates and app layout

## Key files
- `Scripts/generate_app_icon.swift`
- `Scripts/rus_to_prompt_confidence_semantics.py`
- `Scripts/rus_to_prompt_stats_aggregate.py`
- `Scripts/rus_to_prompt_stats_bucket.py`
- `Scripts/rus_to_prompt_stats_core.py`
- `Scripts/rus_to_prompt_stress.py`
- `Scripts/rus_to_prompt_stress_confidence.py`
- `Scripts/rus_to_prompt_stress_models.py`
- `Scripts/rus_to_prompt_stress_results.py`
- `Scripts/rus_to_prompt_stress_runner.py`
- `Scripts/rus_to_prompt_stress_runner_confidence.py`
- `Scripts/rus_to_prompt_stress_runner_modes.py`
- `Scripts/rus_to_prompt_stress_runner_resume.py`
- `Scripts/rus_to_prompt_stress_runner_summary.py`
- `Soma/Assets.xcassets/AppIcon.appiconset/AppIcon-128.png`
- `Soma/Assets.xcassets/AppIcon.appiconset/AppIcon-128@2x.png`
- `Soma/Assets.xcassets/AppIcon.appiconset/AppIcon-16.png`
- `Soma/Assets.xcassets/AppIcon.appiconset/AppIcon-16@2x.png`
- `Soma/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png`
- `Soma/Assets.xcassets/AppIcon.appiconset/AppIcon-256@2x.png`

## Open questions
- None logged yet.

# projectmem - Soma

_Last updated: 2026-07-29_

## Project purpose
Soma is a local-first macOS SwiftUI workbench for comparing language-model output and managing per-project coding-tool/MCP configuration. Its bundled Python services provide the MCP gateway and optional voice transcription server.

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
- [OPEN] #0027 Recent Soma recordings are valid WAV files but contain digital silence, causing Whisper to repeat 'Продолжение следует...'. [Soma/ViewModels/ASRManager.swift] (open)
  - Partial attempt: Replaced the reused AVAudioEngine with a fresh engine for every recording so stale USB/sample-rate routes cannot survive into later captures; Debug build succeeded and fresh app launched. [Soma/ViewModels/ASRManager.swift]
  - Failed attempt: Signal guard checked only int16ChannelData, but AVAudioFile processing buffers are Float32; valid microphone audio was falsely rejected. [Soma/ViewModels/ASRManager.swift]
  - Partial attempt: Updated signal validation to inspect Float32 processing buffers; the previously rejected WAV has normal audio at -27.2 dB, Debug build passes, and a fresh app launched for final recording validation. [Soma/ViewModels/ASRManager.swift]
- [OPEN] #0026 AVAudioEngine aborts when ASRManager forces a 48 kHz client format onto 44.1 kHz microphone hardware. [Soma/ViewModels/ASRManager.swift] (open)
  - Partial attempt: Removed the forced mixer format and now creates the converter from the tap buffer's live hardware format; the Debug build passes, but the 44.1 kHz device still needs a recording smoke test. [Soma/ViewModels/ASRManager.swift]
- [DONE] #0025 The floating global-voice island appears to animate expensive blur/gradient effects at display refresh rate while idle, causing high CPU/GPU compositor contention and game stutter. [Soma global voice island UI (investigation pending)] -> finishAndPaste()'s error catch block now calls overlay.hide(after: 1.4), matching every other exit path, so a translation/prompt-building failure no longer leaves the blurred voice-island window parked on-screen forcing sustained WindowServer recompositing. Xcode Debug build passes. [Soma/GlobalVoiceController.swift] (fixed)
  - Partial attempt: Paused the glass TimelineView outside recording and processing; the main Soma Debug target builds successfully, but runtime CPU profiling has not yet been repeated. [Soma/GlobalVoiceController.swift]
  - Partial attempt: Root cause confirmed via live profiling: Soma.app itself stays near 0% CPU, but WindowServer sustains ~18-22% CPU continuously. finishAndPaste()'s catch block never calls overlay.hide(), so any translation/prompt-building error leaves the floating island window (with its blur/gradient LiquidGlassSurface) parked on-screen indefinitely, forcing WindowServer to keep recompositing the blurred backdrop layer. [Soma/GlobalVoiceController.swift]
- [DONE] #0024 Stopping the global Right Command recording can leave Soma visibly stuck in the Recording state. [Soma/GlobalVoiceController.swift] -> Normal app termination now cancels global recording and disables the event tap before Soma exits. [Soma/SomaApp.swift] (fixed)
  - Partial attempt: Made global listener shutdown cancel any active recording before removing the event tap. [Soma/GlobalVoiceController.swift]
- [DONE] #0023 Soma asks for the login keychain password on every relaunch when reading the voice-server token. [Soma/VoiceServerTokenStore.swift] -> Soma no longer prompts for the Keychain voice-server token on relaunch; rebuilt app runs and defaults-backed server health check returns 200. [Soma/VoiceServerTokenStore.swift] (fixed)
- [DONE] #0022 Voice Server test is blocked by macOS App Transport Security for the HTTP Tailscale server URL. [Soma.xcodeproj/project.pbxproj] -> Soma now permits the private HTTP Tailscale voice-server URL via a narrow ATS exception; rebuilt app runs and token health check returns 200. [Soma/Info.plist] (fixed)
- [DONE] #0021 Voice to Text remote Test Server has no visible result and recordings list overwhelms the page. [Soma/Views/VoiceToTextView.swift] -> Voice to Text now shows explicit remote server online/offline state and collapses older recordings after the newest five; main app build passes. [Soma/Views/VoiceToTextView.swift] (fixed)
  - Partial attempt: Added explicit remote server connection state, visible Voice to Text status row, and collapsible older recordings list. [Soma/Views/VoiceToTextView.swift]
- [DONE] #0020 Added voice-server status/settings endpoints plus backend health/configure support; 16 voice-server unittest cases pass. [Soma/voice_server.py; Soma/voice_asr_backend.py; tests/test_soma_voice_server.py] -> Native menu bar Soma Voice Server target, backend status/settings API, tests, local builds, and M1 install smoke are complete. [SomaVoiceServer; Soma/voice_server.py; Soma/voice_asr_backend.py] (fixed)
  - Failed attempt: Live smoke submitted a test job but the polling shell script failed because it used zsh's read-only status variable. [M1 live smoke]
  - Failed attempt: Second live-smoke poll failed from nested shell quoting around Python JSON field access. [M1 live smoke]
  - Failed attempt: Final status summary command failed from nested shell quoting around Python f-string JSON keys; rerunning with heredoc-safe quoting. [M1 final smoke]
- [DONE] #0019 Soma Voice Server launcher appears to do nothing because it exits after a notification and stale Launchpad entries still show old Soma builds. [M1 /Applications/Soma Voice Server.app] -> Soma Voice Server launcher now displays a status dialog on open, old generated Soma app bundles are removed, and server health/launcher smoke pass. [M1 /Applications/Soma Voice Server.app] (fixed)
- [DONE] #0018 M1 live voice-server smoke could not bind port 8765 because another local process already used it. [~/soma-voice-server-test/Soma/voice_server.py] -> Live smoke uses a free localhost port on the M1 and broker health succeeds without disturbing the existing CI Scope Broker on 8765. [~/soma-voice-server-test] (fixed)
- [DONE] #0017 Remote voice-server test bundle was missing Python support modules needed by soma_test_bootstrap. [~/soma-voice-server-test/tests/soma_test_bootstrap.py] -> Remote test bundle now includes needed Python support files and uses the existing Python 3.11 ASR venv, so voice-server unit tests pass on the M1. [~/soma-voice-server-test] (fixed)
  - Partial attempt: Synced Soma top-level Python support files into the remote voice-server test bundle. [~/soma-voice-server-test/Soma]
  - Failed attempt: Remote unit test still failed because system python3 is 3.9 and Soma gateway test bootstrap needs Python 3.10+ syntax. [~/soma-voice-server-test/tests]
- [DONE] #0016 Review found remote voice client IDs can be invalid HTTP header values and broker backend log handles can leak. [Soma/ViewModels/ASRManager.swift; Soma/voice_server.py] -> remote client IDs are now header-safe UUIDs and backend log handles close after process spawn; Python tests, diff check, and clean Xcode build pass [Soma/ViewModels/ASRManager.swift; Soma/voice_server.py] (fixed)
- [DONE] #0015 Review found silent remote health checks can still overwrite recording status and stalled uploads can pin voice-server handler threads. [Soma/ViewModels/ASRManager.swift; Soma/voice_server.py] -> silent remote health checks no longer overwrite recording status; stalled uploads return retryable 408 before queueing [Soma/ViewModels/ASRManager.swift; Soma/voice_server.py; tests/test_soma_voice_server.py] (fixed)
- [DONE] #0014 Internet-loss review found partial remote uploads can enqueue corrupt audio and retryable voice-server errors are ignored by the client. [Soma/voice_server.py; Soma/ViewModels/ASRManager.swift] -> Internet-loss hardening confirmed: incomplete uploads do not queue jobs, retryable server errors drive client retry/resubmit, 58 Python tests pass, diff check passes, and Xcode Debug build passes. [Soma/voice_server.py; Soma/ViewModels/ASRManager.swift; tests/test_soma_voice_server.py] (fixed)
- [DONE] #0013 Current review found remote ASR idle handling, global hotkey retry, health concurrency, launch agent config, and upload-size weak spots. [Soma/voice_server.py; Soma/voice_asr_backend.py; Soma/GlobalVoiceController.swift; Soma/ViewModels/ASRManager.swift] -> Closed review issues with server/client hardening and regression tests; diff check, Python unittest suite, and Xcode Debug build all pass. [Soma/voice_server.py, Soma/voice_asr_backend.py, Soma/GlobalVoiceController.swift, Soma/Views/VoiceToTextView.swift, tests/test_soma_voice_server.py] (fixed)
- [DONE] #0012 Global Right Command paste can stay stuck on the Accessibility prompt after the user grants access. [Soma/GlobalVoiceController.swift] -> Global Right Command paste now retries Accessibility trust while permission is pending, so granting access can start the listener without another toggle. [Soma/GlobalVoiceController.swift] (fixed)
  - Partial attempt: Added a pending-permission retry loop so Global Right Command paste starts once Accessibility trust appears. [Soma/GlobalVoiceController.swift]
- [DONE] #0011 Soma Voice Server review found auth, cancel cleanup, and client token storage issues [Soma/voice_server.py; Soma/Views/VoiceToTextView.swift; Soma/ViewModels/ASRManager.swift] -> Soma Voice Server review issues fixed: auth cannot silently disable, canceled queued jobs are finalized and cleaned up, and client tokens are stored in Keychain. [Soma/voice_server.py; Soma/VoiceServerTokenStore.swift; Soma/Views/VoiceToTextView.swift; Soma/ViewModels/ASRManager.swift; tests/test_soma_voice_server.py] (fixed)
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
- Soma Voice Server omits DELETE/cancel job API until a real client caller needs it; clients submit and poll only. [Soma/voice_server.py; Soma/ViewModels/ASRManager.swift]
- Soma is a SwiftUI macOS application with separate Python MCP and voice-server entry points; UI state is not owned by either Python process.
- SomaApp owns one shared ASRManager and GlobalVoiceController so recording state survives individual WindowGroup windows.

## Notes
- Cleanup: remove evidence-compiler UI (Prepare Packet, packets, projects, diagnostics, scout)
- docs: reframe SOMA as local model bench + per-project control panel
- Improve Soma extension updates and app layout
- New feature: Add project overview memory tools and global voice paste [.gemini/settings.json.soma-backup-20260708-014730]
- M1 Soma Voice Server installed as LaunchAgent com.daliys.soma.voice-server from ~/soma-voice-server-test on Tailscale port 18765; token is stored only on the M1 in server.token/plist, not in docs. [Soma/voice_server.py]
- Local Soma client defaults now point to the installed M1 Voice Server at http://100.80.30.74:18765 with token stored in Keychain service Daliys.Soma.VoiceServer. [Soma/Views/VoiceToTextView.swift]
- Soma app icon generation defaults to SomaIcon.png; SomaServer.png remains the source image for a future separate server-app icon set. [Scripts/generate_app_icon.swift]
- M1 has one visible Soma Voice Server launcher app at /Applications/Soma Voice Server.app using SomaServer.icns; it checks/starts LaunchAgent com.daliys.soma.voice-server without restarting a healthy server. [M1 /Applications/Soma Voice Server.app]
- Implementing the native menu bar Soma Voice Server as a separate Xcode target in the same repo; main Soma keeps SomaIcon, server app uses SomaServer and controls the LaunchAgent. [Soma Voice Server native app]
- projectmem MCP is bound to the unrelated Soma project while the active checkout is ForkHorizon/NexusUnity; do not use it to log NexusUnity work.

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

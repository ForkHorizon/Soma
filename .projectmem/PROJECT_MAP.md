# Project Map - Soma

## Project purpose

Soma is a local-first macOS SwiftUI workbench for comparing language-model output and managing per-project coding-tool/MCP configuration. Its bundled Python services provide the MCP gateway and optional voice transcription server.

## Main components

- `Soma/SomaApp.swift` — SwiftUI application entry point; owns the shared app, model, queue, and global-voice state.
- `Soma/ContentView.swift`, `Soma/Views/` — macOS application screens, including voice-to-text UI.
- `Soma/ViewModels/ASRManager.swift` and `Soma/GlobalVoiceController.swift` — recording lifecycle and global Right Command control.
- `Soma/soma_mcp_server.py` — MCP gateway entry point used by Codex, Gemini, and Hermes configurations.
- `Soma/voice_server.py` and `Soma/voice_asr_backend.py` — optional HTTP voice transcription service.
- `tests/` — Python regression tests and fixture projects.
- `Soma.xcodeproj/` — Xcode project for the main macOS application and its targets.

## Relationships

`SomaApp` supplies one `ASRManager` and one `GlobalVoiceController` to the SwiftUI interface. The global controller starts/stops recording through the manager; the voice UI observes that manager's state. The Swift app and Python MCP/voice processes are separate runtime entry points.

## Suggested first reads

For app lifecycle and UI: `Soma/SomaApp.swift`, then `Soma/ContentView.swift`.
For voice behavior: `Soma/GlobalVoiceController.swift`, `Soma/ViewModels/ASRManager.swift`, and `Soma/Views/VoiceToTextView.swift`.
For gateway work: `README.md` and `Soma/soma_mcp_server.py`.

# SOMA.md

## Purpose

Soma is a local-first evidence compiler for coding agents. The daily product loop is intentionally simple:

1. Choose this project.
2. Describe one concrete coding task.
3. Prepare a compact evidence packet.
4. Paste that packet into Codex, Claude, Gemini, Hermes, or another coding model.
5. For Codex, copy `Use with Codex` and keep follow-up context inside Soma tools.
6. Mark the packet useful or not useful.

The near-term goal is comfort and daily use, not more features.

## Important Paths

- `Soma/Views/RelayView.swift`: primary Prepare Packet workflow.
- `Soma/Views/ProjectSetupView.swift`: simple project readiness screen.
- `Soma/Views/PacketsView.swift`: real packet history and usefulness feedback.
- `Soma/Views/DiagnosticsView.swift`: advanced screens moved out of the main workflow.
- `Soma/ViewModels/RelayViewModel.swift`: packet preparation flow.
- `Soma/ViewModels/SomaViewModel+Packets.swift`: local packet history.
- `Soma/scout_pipeline_module/`: deterministic evidence selection and packet construction.
- `Soma/gateway/`: MCP gateway and client config integration.

## Commands

Run Python tests:

```bash
PYTHONPATH=/Users/daliys/Daliys/Swift/Soma/Soma \
PYTHONDONTWRITEBYTECODE=1 \
TMPDIR=/tmp \
/opt/homebrew/bin/python3 -m unittest discover -s tests -p 'test_*.py'
```

Build the macOS app:

```bash
xcodebuild -project Soma.xcodeproj -scheme Soma -configuration Debug -destination 'platform=macOS' build
```

Check gateway status:

```bash
/opt/homebrew/bin/python3 Soma/soma_mcp_server.py --status-json --project-root /Users/daliys/Daliys/Swift/Soma
```

## Product Rules

- Do not add new first-layer features until Soma has been used on at least five real tasks.
- Before the next feature wave, prove three real tasks with useful packets and at least one live Soma follow-up when context is missing.
- Keep `Prepare Packet` as the primary route.
- Keep MCP, Graphify, Nexus, Local AI, raw logs, benchmarks, and token utilities in Diagnostics.
- Treat optional systems as optional, not as scary failures.
- Prefer changes that make the app calmer, clearer, and faster to use.

## Acceptance Notes

A useful packet should make the next coding-agent prompt easier, smaller, or more grounded. If a packet misses obvious files or feels like extra work, mark it `Not useful` and improve the selection or UI before adding features.

The `Packets` screen is the product truth source. It should show selected files, useful/not useful status, missed files, why a packet failed, final outcome, and whether Codex used live Soma tools after the packet.

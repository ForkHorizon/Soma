# Soma UI/UX Direction

This document captures product and navigation decisions for the next Soma UI pass. It is intentionally a living planning note, not an implementation spec.

The actionable task sequence is split into separate files under `docs/ui-ux-plan/`, starting with `docs/ui-ux-plan/00-sequence-overview.md`.

## Design Process Rule

These notes are not the final UI design.

Soma currently has too many concepts mixed together, so the redesign must be broken into smaller confirmed pieces. Each major screen or feature area needs its own UX pass before implementation.

Process for each screen/area:

1. Define the user goal.
2. Decide what belongs on the first visible layer.
3. Decide what moves to secondary/advanced detail.
4. Create a focused layout/spec/mock.
5. Review and confirm the direction with the user.
6. Implement only after the screen direction is clear.

Do not do another broad redesign where every feature is moved at once without confirming the individual screen layouts.

Screens/areas that need separate confirmation:

- Projects / Workspace selection
- Prepare Packet
- Prompt Builder
- Local AI settings
- Project Context / Project Health
- Graph / Graphify configuration
- Logs / Activity / Audit Trail
- System Status / Diagnostics
- Scout / External Tools
- Token Calculator
- Model downloads and runtime resources
- macOS menu bar / background operation

## Current Problem

Soma currently exposes too many concepts at the same level:

- packet preparation
- prompt improvement
- local file exploration
- local model settings
- MCP/runtime status
- logs and diagnostics
- graph and Unity/Nexus state

The result is a UI that feels like a technical dashboard instead of a clear tool. The next redesign should reduce visible modes, make the first action obvious, and move advanced/debug surfaces away from the main workflow.

## Decisions So Far

### Prepare Packet Stays Primary

`Prepare Packet` is the main product workflow.

User intent:

> I have a coding task. Soma should gather the right evidence and create a compact packet I can copy into another coding model.

This should be the default route and the most visually prominent screen.

Primary input meaning:

> Describe the coding task, bug, feature, failing test, or review goal.

### Prompt Builder Stays, But Secondary

`Prompt Builder` remains in the product, but it should not compete with Prepare Packet.

User intent:

> I have a rough or unclear task. Soma should turn it into a stronger, model-ready prompt.

Open UX question:

- Keep it as a secondary sidebar route under Workflow, or
- Fold it into Prepare Packet as an optional mode/toggle such as `Improve rough prompt first`.

For now, keep it available but visually secondary.

### Scout Files Moves Away From Main Workflow

`Scout Files` / Scout mode is useful, but it is not part of the main packet workflow.

User intent:

> Ask local Ollama a direct question about project files without creating a packet.

This is more like an advanced/external/local exploration tool. It should move away from the primary navigation.

Possible future placements:

- `External Tools`
- `Advanced`
- `Local Tools`
- Hidden behind Local AI as `Ask Local AI about files`

Open product question:

- Keep Scout as an advanced tool, or
- Remove it from the main app UI entirely while keeping backend code available.

No code should be deleted until this is decided.

### Project Workspace Model Becomes Primary

Soma should behave like a project/workspace app, not a global settings dashboard.

The primary UI object should be:

> Project / Workspace

When a user selects or opens a project, Soma should load that project's local context and run packet preparation inside that project.

Accepted direction:

- Add a first-class Projects UI with folders/workspaces.
- Selecting a project opens a workspace context, not just a global root path.
- `Prepare Packet` runs inside the opened project context.
- Project setup actions should write to local project files, not global app settings.
- Global settings should become defaults/fallbacks only.
- Per-project settings should override global defaults when a project is active.

Project-local files may include:

```text
project/
  SOMA.md
  AGENTS.md
  GEMINI.md
  .soma/
    project.json
```

The exact file set is still open, but the product direction is clear: project context belongs in the project.

Examples of project-local state:

- project description and purpose
- important folders and ignored folders
- build/test commands
- Codex/Gemini/Hermes instructions
- packet preparation defaults
- project health and setup metadata

Global settings should remain for:

- default model choices
- local AI role model choices
- global recent projects
- app-level UI preferences
- fallback behavior when a project has no local profile

Important v1 constraint:

> Local AI model role selection stays global for now. Do not add per-project local model overrides in the first workspace redesign.

Rationale:

- The user wants one global place to choose which local model is used for each Soma mode/role.
- Per-project model overrides would add more complexity before the basic UI is clear.
- The Local AI screen should move under Settings and be visually simplified, not expanded into project-specific configuration.

Local AI v1 roles remain:

- Scout
- Planner / Ranker
- Analyst
- Translator

Important UX rule:

> Configure Project should configure the selected project locally. It should not silently mutate global app behavior.

Opening a project should make context explicit:

```text
Project: UnityTestForNexus
Context: SOMA.md loaded
Models: project overrides active
Health: 1 warning
```

This replaces the current mental model where the user chooses a global root and then repeatedly explains the working context.

### Project Health And Project Analytics

`Project Health` should become more than a runtime status page.

It should explain whether the selected project is ready for Soma and how Soma is being used inside that project.

Future project health information:

- project context status, for example `SOMA.md` present/missing
- agent instruction status, for example `AGENTS.md`, `GEMINI.md`
- graph status and freshness
- important/ignored path configuration
- approximate project size and number of files
- how often the project was used with Soma
- recent packet runs for this project
- recent agent/tool usage for this project
- recurring warnings or missing evidence
- setup recommendations

UX direction:

- Show a concise `Ready / Needs Setup / Needs Attention` summary first.
- Show project usage and file/context stats second.
- Show detailed diagnostics only after expansion.
- Keep this project-scoped, not global.

Open question:

- Should Project Health be a standalone route, or part of each opened Project workspace overview?

### Graph / Graphify Configuration

Graph/Graphify is an important separate area and needs its own redesign.

Current direction:

- Graph functionality is useful and should remain.
- It should not be a small hidden status chip only.
- The app should let users configure graph behavior for different project types.
- Graph settings should be understandable from inside Soma, not only through external commands.

Future Graph/Graphify settings may include:

- enable/disable graph for the project
- build/update graph
- graph freshness and last update time
- project type presets
- included paths
- ignored paths
- file type filters
- max file size / excluded generated files
- graph storage location
- graph rebuild strategy
- graph health warnings
- connection between graph context and Prepare Packet

Project type examples:

- Swift/macOS app
- Unity project
- Python backend
- web app
- mixed monorepo

UX direction:

- Treat Graph as project configuration, not just global runtime state.
- Show a small summary in Project Health.
- Put detailed configuration in a dedicated Graph settings panel/screen.
- Keep advanced graph internals collapsed by default.

Open implementation question:

- Which Graphify options are already configurable today, and which require backend/config changes?

## Proposed Navigation Direction

Recommended sidebar structure:

```text
Main
  Prepare Packet

Workflow
  Prompt Builder

Settings
  Local AI
  Project Health

Advanced
  Scout Files / Ask Local AI
  Logs
  System Status
```

Alternative stricter structure:

```text
Main
  Prepare Packet

Tools
  Prompt Builder

Settings
  Local AI
  Project Health

Advanced
  External Tools
  Logs
```

In both structures, Prepare Packet is the only obvious first step.

## Settings Layout Direction

### Local AI

`Local AI` belongs under `Settings`, not the main workflow.

Purpose:

> Choose which global local model Soma uses for each mode/role.

The current Local AI screen is too visually noisy. It should be redesigned as a compact settings surface, likely a table or inspector list instead of large equal-weight cards.

Preferred v1 layout:

```text
Role              Model                       Status        Action
Scout             gemma4:e4b                  Not loaded    Load
Planner / Ranker  gemma4:e4b                  Installed     Change
Analyst           qwen3-coder:30b             Installed     Change
Translator        Auto                        Fallback      Change
```

Design requirements:

- one row per role
- show model name clearly
- show installed / loaded state without large cards
- keep custom model input available but secondary
- keep installed model list collapsed by default
- show recent local model calls only as advanced detail
- do not make Local AI look like a primary workflow

Future direction, not v1 scope:

- Add model acquisition/download management inside Local AI settings.
- Users should be able to find and download open-source models, not only select already installed models.
- Downloads should show visible progress, current stage, size, speed when available, and clear failure/retry actions.
- Model download/install should feel like an app workflow, not a hidden terminal operation.

Longer-term model provider direction:

- Local AI roles should eventually support either a local model provider or an API provider.
- Example: Scout/Ranker/Analyst/Translator could use Ollama locally, or a configured API model.
- API configuration would need provider, model name, key/token handling, limits, privacy warning, and cost/rate-limit visibility.
- This is a larger product and architecture task. Do not mix it into the first UI cleanup unless explicitly planned.

### Local AI Runtime And Resource Management

Local AI settings should eventually include runtime/resource controls, not only model selection.

Problem:

- Local models can stay loaded in memory after use.
- This can consume RAM/VRAM and slow down the computer.
- The user needs to understand which model is loaded, how much memory it uses, and when it will be unloaded.

Required future capabilities:

- Show which local models are currently loaded.
- Show current selected role model and whether it is loaded/running.
- Show model memory usage when available.
- Show GPU usage when available.
- Show CPU usage when available.
- Show whether the model is idle or actively processing.
- Show time remaining until auto-unload.
- Allow manual load/unload.
- Allow configuring auto-unload behavior.

User settings to consider:

- enable/disable auto-unload
- unload after N minutes idle
- keep Scout model warm while app is open
- unload all models when project/workspace closes
- unload all models when Soma quits
- warn before loading very large models
- maximum allowed memory usage before warning

Possible UI placement:

- `Settings > Local AI` should contain model role selection and runtime resource controls.
- A compact runtime indicator can appear in the project/top health area.
- Detailed CPU/GPU/RAM charts should be advanced/collapsed by default.

Important UX rule:

> Resource details should be visible when needed, but they should not compete with Prepare Packet.

Open implementation question:

- Determine which metrics are available from Ollama APIs versus which require macOS system APIs or shell commands.

## Observability And Audit UX

Soma should make internal activity understandable without turning the main UI into a raw log dashboard.

Current problem:

- Logging exists, but the user cannot easily understand what actually happened.
- It is not clear enough who sent a request, what the request contained, which model/tool handled it, how much was sent, what was returned, and what the outcome was.
- Showing all of this directly in the main UI would overload the interface.

Future direction:

- Add a clear activity/audit experience that explains what happened inside Soma.
- Each meaningful request should be inspectable.
- The UI should show activity in layers:
  - summary first
  - important warnings/errors second
  - request/response details on demand
  - raw payloads/logs only in advanced detail

Information we eventually want visible:

- request source/client, for example UI, Codex, Gemini, Hermes, MCP client, local workflow
- request type, for example Prepare Packet, tool call, local model call, model download, agent config
- input summary and, when safe, exact input/payload
- selected project/workspace
- selected model/provider/role
- tools or pipeline stages used
- token counts in/out and estimated savings
- duration and status
- warnings, errors, retries, fallbacks
- copied/exported packet or output metadata
- audit/run ID and related files

Possible UX composition:

- Keep the main screen simple.
- Show a compact `Latest Activity` / `Activity Timeline`.
- Allow clicking an activity row to open a detail drawer, popover, or inspector panel.
- Keep raw JSON/log payloads collapsed by default.
- Use filters and grouping in the Logs/Activity screen instead of showing every field in every row.
- Consider a dedicated `Activity` or `Audit Trail` route if Logs remains too technical.

Open UX question:

- Should this become a redesigned `Logs` screen, or a separate higher-level `Activity` screen with raw logs hidden under advanced details?

## Full Logs Logic And UI Redesign

**Logs need a full logic and UI redesign. This is a high-priority product cleanup area.**

Current problem:

- Logs can be cleared, but the UI still feels like they were not really deleted.
- It is unclear what was deleted: visible filtered entries, today's logs, a session, or all historical logs.
- The current functionality is too small and too technical.
- The Logs screen does not clearly explain the difference between sessions, runs, days, raw log files, structured logs, and audit traces.
- The user needs more control and clearer feedback.

Required future capabilities:

- Delete/clear current visible filtered logs.
- Delete a single session/run.
- Delete today's logs.
- Delete logs for a selected date range.
- Delete all logs.
- Delete or reset audit traces separately when appropriate.
- Start a new clean session.
- Refresh/reload logs with obvious feedback.
- Show exactly what was deleted and what remains.
- Show empty state that confirms logs are actually empty for the selected scope.

Possible log scopes:

- current UI session
- selected run/task
- today
- selected date
- date range
- all local logs
- audit traces
- raw payload captures

UX requirements:

- Destructive actions need clear labels and confirmation.
- `Clear` should never be ambiguous.
- Use labels like `Clear Visible`, `Delete Today`, `Delete Run`, `Delete All Logs`.
- After deletion, show a confirmation message and update counts immediately.
- Empty state should include the active scope, for example `No logs for today`.
- Keep raw logs/details available, but do not make them the first layer.

Open design question:

- Should logs become part of a higher-level `Activity` screen with raw logs as an advanced tab, or remain a dedicated `Logs` route with a better information model?

## Future Feature: Agent Usage Analysis

This is a future product feature, not part of the immediate UI cleanup.

Problem:

- Soma can be used by Codex, Gemini, Hermes, and other agents.
- We can log activity, but we do not yet have a product surface that explains whether Soma was used well.
- The user cannot easily answer:
  - how often agents used Soma tools
  - which tools were used
  - which tools were ignored
  - whether agents should have used tools but did not
  - whether tool results improved the work
  - where the project setup or instructions failed

Feature concept:

> A project-level analysis mode that investigates what went wrong or could be improved in agent usage for a specific working project.

Possible names:

- `Agent Analysis`
- `Usage Review`
- `Project Retrospective`
- `Tool Usage Research`
- `What Went Wrong`

Expected behavior:

- Read many logs and audit traces for a selected project.
- Group activity by project, run, agent/client, task, and tool.
- Identify missed opportunities where an agent did not call Soma tools.
- Identify noisy or low-value tool usage.
- Compare expected tool usage versus actual usage.
- Highlight recurring failures, skipped context, missing evidence, bad prompts, or weak setup.
- Suggest concrete improvements:
  - update `SOMA.md`
  - update `AGENTS.md`
  - update `GEMINI.md`
  - adjust project setup
  - improve packet defaults
  - improve tool descriptions
  - improve model role settings

Possible UI composition:

- Project selector first.
- Time range / run selector.
- Summary of tool usage.
- Findings grouped by severity.
- Timeline of notable runs.
- Recommended changes.
- Raw logs only available as advanced detail.

Important UX rule:

> This should feel like an investigation/report mode, not another raw logs table.

Open product question:

- Should this become part of `Activity / Audit Trail`, or a separate future route under `Insights` / `Research` / `Advanced`?

## Future Direction: macOS Menu Bar And Background Operation

Soma should eventually support a macOS menu bar presence and background operation.

This is a separate product and technical direction, not part of the immediate UI cleanup.

Problem:

- Soma is useful as project infrastructure, not only as a foreground window.
- Long-running tasks, local model runtime, model downloads, MCP gateway state, and activity monitoring may need to continue in the background.
- The user should be able to see key Soma status from the macOS menu bar, near Wi-Fi/battery/system status items.

Menu bar goals:

- Show whether Soma is running.
- Show active project/workspace.
- Show MCP status.
- Show local model loaded/running state.
- Show active background tasks, for example packet preparation, model download, graph update, or analysis.
- Provide quick actions:
  - open Soma
  - open current project
  - prepare packet
  - start/stop MCP
  - load/unload local model
  - pause/stop background jobs

Background operation goals:

- Allow selected tasks to continue when the main window is closed.
- Support background model downloads with progress.
- Support MCP gateway running in the background when enabled.
- Support auto-unload timers for local models.
- Support notifications for completion, failures, warnings, or required user action.

Important UX rule:

> Background mode must be explicit and understandable. The user should always know when Soma is doing work or keeping resources loaded.

Open technical questions:

- Which tasks are safe to continue after the main window closes?
- Should MCP background mode be opt-in per project or global?
- How should macOS notifications be configured?
- What should quit mean: close UI only, or stop all background services?

## Token Calculator Integration

The Token Calculator should become an in-app tool, not a separate floating window.

Current problem:

- Token Calculator currently opens as a separate window.
- This makes it feel disconnected from the rest of Soma.
- It is another utility surface that needs the same UI/UX cleanup as the main app.

Accepted direction:

- Move Token Calculator into the main application navigation.
- Treat it as a utility/tool screen, not a separate app window.
- Redesign the layout to match the new Soma design system.

Possible placements:

- `Tools > Token Calculator`
- `Advanced > Token Calculator`
- inside a future `Utilities` section

Expected redesign direction:

- clear input area for text/prompt
- token count summary
- model/tokenizer selection if supported
- comparison across models/tokenizers if useful
- copy/clear actions
- compact explanation of what the number means
- optional advanced breakdown collapsed by default

Open UX question:

- Should Token Calculator be a standalone route, or embedded as a utility panel inside Prepare Packet / Prompt Builder?

## UI Principles

- The first screen should answer: `What should I do now?`
- Do not show all runtime systems as equal top-level concepts.
- Keep advanced diagnostics reachable, but not visually dominant.
- Use fewer cards and more stable split views.
- Avoid long descriptions in the sidebar.
- Use plain labels with clear input purpose:
  - Prepare Packet: `Describe the coding task`
  - Prompt Builder: `Paste a rough prompt`
  - Scout: `Ask a local file question`
- Do not delete backend or ViewModel actions during the navigation redesign.

## Open Questions

- Should Prompt Builder become a mode inside Prepare Packet?
- Should Scout be renamed to `Ask Local AI`, `Explore Files`, or moved under `External Tools`?
- Should System Status and Logs both remain visible routes, or should they be grouped under one `Diagnostics` route?
- Should the top bar show individual MCP/Local AI/Graph/Unity chips, or one compact `Project Health` control with details inside?

import SwiftUI

struct AdvancedToolsView: View {
    @ObservedObject var somaViewModel: SomaViewModel
    @ObservedObject var scoutViewModel: ScoutViewModel
    @ObservedObject var ollama: OllamaManager
    @Binding var selectedRoute: AppRoute?
    @State private var selectedTool: AdvancedTool = .scout

    enum AdvancedTool: String, CaseIterable, Identifiable {
        case scout = "Ask Local AI"
        case diagnostics = "Diagnostics"
        case future = "Future Platform"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .scout: return "folder.badge.magnifyingglass"
            case .diagnostics: return "stethoscope"
            case .future: return "shippingbox.and.arrow.backward"
            }
        }
    }

    var body: some View {
        SomaPage {
            WorkflowHeader(
                title: "Utilities",
                subtitle: "Optional tools live under Advanced so Prepare Packet stays the primary workflow. Use these for one-off local AI questions, token estimates, and expert diagnostics.",
                icon: "wrench.and.screwdriver",
                tone: .neutral
            )

            utilityOverview

            Picker("Advanced tool", selection: $selectedTool) {
                ForEach(AdvancedTool.allCases) { tool in
                    Label(tool.rawValue, systemImage: tool.icon).tag(tool)
                }
            }
            .pickerStyle(.segmented)

            switch selectedTool {
            case .scout:
                scoutSection
            case .diagnostics:
                diagnosticsSection
            case .future:
                futureSection
            }
        }
    }

    private var utilityOverview: some View {
        SomaSplitWorkbench {
            SomaPanel(title: "Utility Shelf", subtitle: "Fast entry points for tools that are useful but not part of packet preparation.", icon: "square.grid.2x2", tone: .info) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                    utilityCard(
                        title: "Token Calculator",
                        detail: "Estimate prompt and packet size inside the app.",
                        icon: "number.square",
                        tone: .info,
                        actionLabel: "Open Calculator"
                    ) { selectedRoute = .tokenCalculator }
                    utilityCard(
                        title: "Ask Local AI",
                        detail: "Optional Scout workflow for direct file questions without a packet.",
                        icon: "folder.badge.magnifyingglass",
                        tone: ollama.isOllamaRunning ? .good : .neutral,
                        actionLabel: "Open Scout"
                    ) { selectedTool = .scout }
                    utilityCard(
                        title: "Diagnostics",
                        detail: "Expert MCP, Graphify, Nexus, and runtime checks.",
                        icon: "stethoscope",
                        tone: .neutral,
                        actionLabel: "Review Checks"
                    ) { selectedTool = .diagnostics }
                    utilityCard(
                        title: "Future Platform",
                        detail: "Parking lot for downloads, API providers, background mode, and analysis ideas.",
                        icon: "shippingbox.and.arrow.backward",
                        tone: .neutral,
                        actionLabel: "View Roadmap"
                    ) { selectedTool = .future }
                }
            }
        } secondary: {
            StatusBanner(
                title: "Advanced by design",
                detail: "These utilities are intentionally secondary. Project Health owns readiness, Activity owns logs/audit, Prepare Packet owns the main workbench, and Future Platform is documentation only.",
                tone: .info
            )
        }
    }

    private func utilityCard(title: String, detail: String, icon: String, tone: SomaStatusTone, actionLabel: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(tone.color)
                    .frame(width: 20)
                Text(title)
                    .font(.subheadline.bold())
                Spacer()
            }
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionLabel, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(SomaDesign.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
        .overlay(RoundedRectangle(cornerRadius: SomaDesign.radius).stroke(tone.color.opacity(0.16)))
    }

    private var scoutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusBanner(
                title: "Scout is optional and advanced",
                detail: "Use this when you want to ask local Ollama about files directly without creating a packet. The main workflow remains Prepare Packet.",
                tone: .info
            )
            ScoutView(viewModel: scoutViewModel, somaViewModel: somaViewModel, ollama: ollama)
                .frame(minHeight: 600)
                .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
                .overlay(RoundedRectangle(cornerRadius: SomaDesign.radius).stroke(Color.secondary.opacity(0.10)))
        }
    }

    private var diagnosticsSection: some View {
        SomaSplitWorkbench {
            SomaPanel(title: "Diagnostics", subtitle: "Expert-only runtime checks moved out of the main workflow.", icon: "stethoscope", tone: .neutral) {
                StepChecklist(steps: [
                    WorkflowStep(id: "mcp", title: "MCP Gateway", detail: somaViewModel.somaServerRunning ? "Online" : "Offline until external clients need tools.", tone: somaViewModel.somaServerRunning ? .good : .neutral),
                    WorkflowStep(id: "graph", title: "Graphify", detail: somaViewModel.graphAvailable ? (somaViewModel.graphStale ? "Graph stale" : "Graph fresh") : "No graph found; packet mode still works.", tone: somaViewModel.graphAvailable ? (somaViewModel.graphStale ? .warning : .good) : .neutral),
                    WorkflowStep(id: "nexus", title: "Nexus Unity", detail: somaViewModel.nexusConnected ? "Connected" : "Offline or not a Unity project.", tone: somaViewModel.nexusConnected ? .info : .neutral),
                    WorkflowStep(id: "local-ai", title: "Local AI", detail: ollama.isOllamaRunning ? "Ollama available" : "Offline; role settings are still saved.", tone: ollama.isOllamaRunning ? .good : .neutral),
                ])
                HStack(spacing: 8) {
                    Button("Open System Status") { selectedRoute = .systemStatus }
                        .buttonStyle(.borderedProminent)
                    Button("Refresh Status") { somaViewModel.refreshSomaStatus() }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
        } secondary: {
            SomaPanel(title: "What belongs here", subtitle: "Diagnostics stay reachable but should not be a first action.", icon: "info.circle", tone: .info) {
                Text("System Status, MCP smoke tests, raw runtime state, and deep graph diagnostics belong under Advanced. Project Health owns user-facing readiness; Prepare Packet owns the primary workflow.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var futureSection: some View {
        VStack(alignment: .leading, spacing: SomaDesign.panelSpacing) {
            StatusBanner(
                title: "Future platform work is parked",
                detail: "This page is intentionally non-operational. It records larger product ideas without adding model downloads, API keys, resource monitors, or background services to the near-version UI.",
                tone: .neutral
            )

            SomaSplitWorkbench {
                futureCard(title: "Model Downloads", icon: "arrow.down.circle", points: [
                    "Browse/find open-source models and install them inside Soma.",
                    "Show progress, size, speed, stage, failure, retry, and installed state.",
                    "Requires model-source decisions and download management before implementation."
                ])
                futureCard(title: "API Model Providers", icon: "network", points: [
                    "Use API providers instead of local Ollama for roles.",
                    "Configure provider, model, key/token, privacy, cost, and rate-limit warnings.",
                    "Requires secure key handling and a larger architecture decision."
                ])
                futureCard(title: "Agent Usage Analysis", icon: "chart.xyaxis.line", points: [
                    "Investigate how Codex, Gemini, Hermes, and other agents used Soma tools.",
                    "Surface missed tool opportunities, noisy calls, setup failures, and prompt/tool improvements.",
                    "Depends on the Activity/Logs foundation and project-scoped history."
                ])
            } secondary: {
                futureCard(title: "macOS Menu Bar & Background", icon: "menubar.rectangle", points: [
                    "Show active project, MCP/model state, background tasks, quick actions, and notifications.",
                    "Potentially support background MCP, downloads, and auto-unload timers.",
                    "Requires clear lifecycle rules for window close, app quit, and loaded resources."
                ])
                futureCard(title: "Local AI Runtime Monitoring", icon: "gauge.with.dots.needle.67percent", points: [
                    "Track memory, GPU, CPU, active/idle state, auto-unload timing, and resource warnings.",
                    "Depends on available Ollama and macOS metrics.",
                    "Kept out of first Local AI settings redesign to avoid clutter."
                ])
                planningChecklist
            }
        }
    }

    private var planningChecklist: some View {
        SomaPanel(title: "Before anything moves into build", subtitle: "Acceptance criteria for future planning", icon: "checklist", tone: .info) {
            StepChecklist(steps: [
                WorkflowStep(id: "spec", title: "Create a dedicated task/spec", detail: "Do not implement directly from this parking lot.", tone: .neutral),
                WorkflowStep(id: "goal", title: "Confirm the user goal", detail: "Name the problem, target user, and success signal.", tone: .neutral),
                WorkflowStep(id: "layers", title: "Define UI layers", detail: "First visible layer, advanced/detail layer, and empty/error/success states.", tone: .neutral),
                WorkflowStep(id: "data", title: "Identify backend/data requirements", detail: "Secrets, downloads, metrics, logs, lifecycle, and storage must be explicit.", tone: .neutral),
                WorkflowStep(id: "home", title: "Choose the product home", detail: "Decide whether it belongs in Settings, Project Health, Activity, or Advanced.", tone: .neutral),
            ])
        }
    }

    private func futureCard(title: String, icon: String, points: [String]) -> some View {
        SomaPanel(title: title, subtitle: "Parked until a dedicated spec exists.", icon: icon, tone: .neutral) {
            ForEach(points, id: \.self) { point in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundColor(.secondary)
                        .padding(.top, 6)
                    Text(point)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

import AppKit
import SwiftUI

struct GlobalSettingsBar: View {
    @ObservedObject var viewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager
    @Binding var selectedRoute: AppRoute?
    @State private var showRecentRoots = false
    @State private var showRuntimeDetails = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                projectControl
                comfortStatusPill(
                    title: "Setup",
                    value: setupLabel,
                    detail: setupDetail,
                    icon: setupTone == .good ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                    tone: setupTone
                )
                comfortStatusPill(
                    title: "Last Packet",
                    value: viewModel.latestPacketFeedbackLabel(),
                    detail: "Mark each packet useful or not useful after a run.",
                    icon: "tray.full",
                    tone: viewModel.latestPacketFeedbackTone()
                )
                Spacer(minLength: 12)
                Button {
                    selectedRoute = .diagnostics
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(Divider(), alignment: .bottom)
        }
    }

    private var projectControl: some View {
        HStack(spacing: 10) {
            Image(systemName: viewModel.selectedProjectRoot.isEmpty ? "folder.badge.questionmark" : "folder.fill")
                .foregroundColor(viewModel.selectedProjectRoot.isEmpty ? .orange : .blue)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 22)

            Button {
                if viewModel.selectedProjectRoot.isEmpty {
                    chooseProjectRoot()
                } else {
                    showRecentRoots.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Project")
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                    Text(projectLabel)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showRecentRoots, arrowEdge: .bottom) {
                recentRootsPopover
            }

            Button {
                chooseProjectRoot()
            } label: {
                Label("Choose", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 360, alignment: .leading)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
        .overlay(RoundedRectangle(cornerRadius: SomaDesign.radius).stroke(Color.secondary.opacity(0.10)))
    }

    private func comfortStatusPill(title: String, value: String, detail: String, icon: String, tone: SomaStatusTone) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(tone.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.bold())
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.caption.bold())
                    .foregroundColor(tone.color)
                    .lineLimit(1)
            }
        }
        .help(detail)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 190, alignment: .leading)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
        .overlay(RoundedRectangle(cornerRadius: SomaDesign.radius).stroke(tone.color.opacity(0.14)))
    }

    private var setupLabel: String {
        if viewModel.selectedProjectRoot.isEmpty { return "Choose project" }
        return viewModel.projectHealthWarningCount(for: viewModel.selectedProjectRoot) == 0 ? "Ready" : "Needs setup"
    }

    private var setupDetail: String {
        if viewModel.selectedProjectRoot.isEmpty { return "Choose a project before preparing packets." }
        if viewModel.projectContextSummary(for: viewModel.selectedProjectRoot) == "Context missing" {
            return "Add SOMA.md when you want stronger project-specific packets."
        }
        return "Project context is visible. Optional systems stay in Diagnostics."
    }

    private var setupTone: SomaStatusTone {
        if viewModel.selectedProjectRoot.isEmpty { return .warning }
        return viewModel.projectHealthWarningCount(for: viewModel.selectedProjectRoot) == 0 ? .good : .warning
    }

    private var projectLabel: String {
        if viewModel.selectedProjectRoot.isEmpty {
            return "Choose a project"
        }
        return (viewModel.selectedProjectRoot as NSString).lastPathComponent
    }

    private var recentRootsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Projects")
                .font(.caption.bold())
                .foregroundColor(.secondary)
            if viewModel.recentProjectRoots.isEmpty {
                Text("No recent projects yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(viewModel.recentProjectRoots, id: \.self) { root in
                    Button {
                        viewModel.selectProjectRoot(root)
                        showRecentRoots = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: root == viewModel.selectedProjectRoot ? "checkmark.circle.fill" : "folder")
                                .foregroundColor(root == viewModel.selectedProjectRoot ? .blue : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((root as NSString).lastPathComponent)
                                    .font(.subheadline)
                                Text(root)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 320)
    }

    private var runtimeStrip: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    RuntimeStatusItem(
                        title: "MCP",
                        value: viewModel.somaServerRunning ? "Online" : "Offline",
                        detail: mcpDetail,
                        icon: "server.rack",
                        tone: viewModel.somaServerRunning ? .good : (viewModel.selectedProjectRoot.isEmpty ? .warning : .danger),
                        isBusy: viewModel.somaServerBusy,
                        actionTitle: viewModel.somaServerRunning ? "Stop" : "Start",
                        actionDisabled: viewModel.somaServerBusy || viewModel.selectedProjectRoot.isEmpty,
                        disabledReason: viewModel.selectedProjectRoot.isEmpty ? "Choose a project first." : nil,
                        action: {
                            if viewModel.somaServerRunning {
                                viewModel.stopSomaServer()
                            } else {
                                viewModel.startSomaServer()
                            }
                        }
                    )

                    RuntimeStatusItem(
                        title: "Local AI",
                        value: shortModelName(ollama.modelName),
                        detail: ollamaDetail,
                        icon: "cpu",
                        tone: ollama.isOllamaRunning ? (ollama.isModelLoaded ? .good : .warning) : .neutral,
                        isBusy: ollama.isBusy,
                        actionTitle: ollamaButtonLabel,
                        actionDisabled: ollama.isBusy,
                        disabledReason: ollama.isBusy ? "Local model action already running." : nil,
                        action: ollamaAction,
                        secondaryActionTitle: "Models",
                        secondaryAction: { selectedRoute = .localAI }
                    )

                    RuntimeStatusItem(
                        title: "Graph",
                        value: viewModel.graphAvailable ? (viewModel.graphStale ? "Stale" : "Fresh") : "Optional",
                        detail: graphDetail,
                        icon: "point.3.connected.trianglepath.dotted",
                        tone: viewModel.graphAvailable ? (viewModel.graphStale ? .warning : .good) : .neutral,
                        isBusy: viewModel.graphifyBusy,
                        actionTitle: viewModel.graphAvailable ? "Update" : "Build",
                        actionDisabled: viewModel.graphifyBusy || viewModel.systemBusy || viewModel.selectedProjectRoot.isEmpty,
                        disabledReason: viewModel.selectedProjectRoot.isEmpty ? "Choose a project first." : nil,
                        action: { viewModel.initializeGraphify() }
                    )

                    RuntimeStatusItem(
                        title: "Unity",
                        value: viewModel.nexusConnected ? "Connected" : "Skipped",
                        detail: viewModel.nexusConnected ? "Nexus is available for Unity-specific tools." : "Unity/Nexus is optional and not required for packet mode.",
                        icon: "circle.grid.3x3.fill",
                        tone: viewModel.nexusConnected ? .info : .neutral,
                        isBusy: false,
                        actionTitle: nil,
                        actionDisabled: true,
                        disabledReason: nil,
                        action: nil
                    )
                }
                .padding(.vertical, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                showRuntimeDetails.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .popover(isPresented: $showRuntimeDetails, arrowEdge: .bottom) {
                runtimeDetailsPopover
            }
        }
    }

    private var mcpDetail: String {
        if viewModel.selectedProjectRoot.isEmpty {
            return "Choose a project before starting the gateway."
        }
        return viewModel.somaServerRunning ? "Ready for clients that use Soma MCP." : "Start this when an AI client needs live Soma tools."
    }

    private var ollamaDetail: String {
        if !ollama.isOllamaRunning {
            return "Scout model: \(ollama.modelName). Ollama is required for Scout and optional model stages."
        }
        if ollama.isModelLoaded {
            return "Scout model \(ollama.modelName) is loaded. Ranker: \(ollama.rankerModelName). Analyst: \(ollama.analystModelName)."
        }
        return "Ollama is running. Load Scout model \(ollama.modelName) when you need file exploration."
    }

    private var graphDetail: String {
        if viewModel.selectedProjectRoot.isEmpty {
            return "Graphify checks run after a project is selected."
        }
        if viewModel.graphAvailable && viewModel.graphStale {
            return "Graph exists but may be stale. Update it before graph-heavy prompts."
        }
        if viewModel.graphAvailable {
            return "Project graph is available for optional context."
        }
        return "No graph found. Packet mode still works without it."
    }

    private var ollamaButtonLabel: String {
        if !ollama.isOllamaRunning { return "Launch" }
        return ollama.isModelLoaded ? "Stop" : "Load"
    }

    private var runtimeDetailsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Project & Runtime")
                .font(.headline)
            Text("Prepare Packet works best after a project is selected. MCP is only needed for live client tool calls. Local AI and Graphify are optional accelerators.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Project: \(viewModel.selectedProjectRoot.isEmpty ? "not selected" : viewModel.selectedProjectRoot)")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Text("Graphify: \(graphDetail)")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Local AI: \(ollamaDetail)")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Translator: \(ollama.translatorModelName.isEmpty ? "Auto" : ollama.translatorModelName)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(width: 360)
    }

    private var latestActivity: some View {
        Group {
            if let last = viewModel.logEntries.first(where: { $0.event == "tool_call" || $0.event == "local_model_call" }) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(last.isError ? Color.red : last.isDegraded ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Latest Activity")
                            .font(.caption2.bold())
                            .foregroundColor(.secondary)
                        Text(activitySummary(last))
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(SomaDesign.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
                .frame(maxWidth: 360, alignment: .trailing)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.path")
                        .foregroundColor(.secondary)
                    Text("No activity yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func activitySummary(_ entry: SomaLogEntry) -> String {
        var parts = [entry.displayName]
        if let duration = entry.duration_ms, duration > 0 {
            parts.append("\(Int(duration))ms")
        }
        if entry.totalTokens > 0 {
            parts.append("\(entry.totalTokens) tok")
        }
        return parts.joined(separator: " | ")
    }

    private func shortModelName(_ model: String) -> String {
        if model.count <= 18 { return model }
        return String(model.prefix(15)) + "..."
    }

    private func ollamaAction() {
        if !ollama.isOllamaRunning {
            ollama.launchOllama()
        } else if ollama.isModelLoaded {
            ollama.stopModel()
        } else {
            ollama.startModel()
        }
    }

    private func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Project Root"
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        viewModel.selectProjectRoot(path)
    }
}

private struct RuntimeStatusItem: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tone: SomaStatusTone
    let isBusy: Bool
    let actionTitle: String?
    let actionDisabled: Bool
    let disabledReason: String?
    let action: (() -> Void)?
    var secondaryActionTitle: String?
    var secondaryAction: (() -> Void)?
    @State private var showDetail = false

    var body: some View {
        HStack(spacing: 8) {
            statusIcon

            Button {
                showDetail.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                    Text(value)
                        .font(.caption.bold())
                        .foregroundColor(tone.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                detailPopover
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(actionDisabled)
                    .help(actionDisabled ? (disabledReason ?? "Action unavailable") : detail)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(width: 190, alignment: .leading)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
        .overlay(RoundedRectangle(cornerRadius: SomaDesign.radius).stroke(tone.color.opacity(0.16)))
    }

    private var statusIcon: some View {
        Group {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: icon)
                    .foregroundColor(tone.color)
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .frame(width: 18)
    }

    private var detailPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundColor(tone.color)
                Spacer()
            }
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let disabledReason, actionDisabled {
                StatusBanner(title: "Action unavailable", detail: disabledReason, tone: .warning)
            }
            if let secondaryActionTitle, let secondaryAction {
                Button(secondaryActionTitle) {
                    showDetail = false
                    secondaryAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 310)
    }
}

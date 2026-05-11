import SwiftUI

struct GlobalSettingsBar: View {
    @ObservedObject var viewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager
    @State private var showRecentRoots = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                projectSection
                divider
                mcpSection
                divider
                ollamaSection
                Spacer()
                graphSection
                divider
                nexusSection
                divider
                activityFeed
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(Divider(), alignment: .bottom)
        }
    }

    // MARK: - Project

    private var projectSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundColor(viewModel.selectedProjectRoot.isEmpty ? .secondary : .blue)
                .font(.system(size: 12))

            if viewModel.selectedProjectRoot.isEmpty {
                Text("No Project")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Button {
                    showRecentRoots.toggle()
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Project")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text((viewModel.selectedProjectRoot as NSString).lastPathComponent)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showRecentRoots, arrowEdge: .bottom) {
                    recentRootsPopover
                }
            }

            Button {
                chooseProjectRoot()
            } label: {
                Image(systemName: "pencil.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Change project root")
        }
    }

    private var recentRootsPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Projects")
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .padding(.bottom, 4)
            ForEach(viewModel.recentProjectRoots, id: \.self) { root in
                Button {
                    viewModel.selectProjectRoot(root)
                    showRecentRoots = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: root == viewModel.selectedProjectRoot ? "checkmark" : "folder")
                            .font(.caption)
                            .foregroundColor(root == viewModel.selectedProjectRoot ? .blue : .secondary)
                        Text((root as NSString).lastPathComponent)
                            .font(.subheadline)
                        Text(root)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
        .padding(12)
        .frame(minWidth: 260)
    }

    // MARK: - MCP Server

    private var mcpSection: some View {
        HStack(spacing: 6) {
            pulseDot(
                color: viewModel.somaServerRunning ? .green : .red,
                pulse: viewModel.somaServerBusy
            )
            VStack(alignment: .leading, spacing: 0) {
                Text("MCP")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(viewModel.somaServerRunning ? "Online" : "Offline")
                    .font(.subheadline.bold())
            }
            Button(viewModel.somaServerRunning ? "Stop" : "Start") {
                if viewModel.somaServerRunning { viewModel.stopSomaServer() }
                else { viewModel.startSomaServer() }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(viewModel.somaServerBusy || viewModel.selectedProjectRoot.isEmpty)
        }
    }

    // MARK: - Ollama

    private var ollamaSection: some View {
        HStack(spacing: 6) {
            pulseDot(
                color: ollama.isOllamaRunning ? (ollama.isModelLoaded ? .green : .orange) : .red,
                pulse: ollama.isBusy
            )
            VStack(alignment: .leading, spacing: 0) {
                Text("AI")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(ollama.isOllamaRunning ? (ollama.isModelLoaded ? "Ready" : "Idle") : "Offline")
                    .font(.subheadline.bold())
            }
            Button(action: ollamaAction) {
                if ollama.isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(ollama.isOllamaRunning ? (ollama.isModelLoaded ? "Stop" : "Load") : "Launch")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(ollama.isBusy)
        }
    }

    // MARK: - Graph status chip

    private var graphSection: some View {
        HStack(spacing: 5) {
            Image(systemName: viewModel.graphAvailable
                  ? (viewModel.graphStale ? "exclamationmark.triangle" : "checkmark.circle.fill")
                  : "circle.slash")
                .font(.system(size: 11))
                .foregroundColor(viewModel.graphAvailable
                                 ? (viewModel.graphStale ? .orange : .green)
                                 : .secondary)
            Text("Graph")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .help(viewModel.graphAvailable
              ? (viewModel.graphStale ? "Graph stale — run graphify update ." : "Graph fresh")
              : "No graph found for this project")
    }

    // MARK: - Nexus chip

    private var nexusSection: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.grid.3x3.fill")
                .font(.system(size: 11))
                .foregroundColor(viewModel.nexusConnected ? .blue : .secondary)
            Text("Unity Plugin")
                .font(.caption2)
                .foregroundColor(viewModel.nexusConnected ? .primary : .secondary)
        }
        .help(viewModel.nexusConnected ? "Unity plugin connected" : "Unity plugin skipped/offline")
    }

    // MARK: - Activity Feed (last tool call)

    private var activityFeed: some View {
        Group {
            if let last = viewModel.logEntries.first(where: { $0.event == "tool_call" }) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(last.isError ? Color.red : last.isDegraded ? Color.orange : Color.green)
                        .frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(last.displayName)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if let dur = last.duration_ms {
                                Text("\(Int(dur))ms")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            if last.totalTokens > 0 {
                                Text("·")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 9))
                                Text("\(last.totalTokens)tok")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.purple.opacity(0.8))
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .help("Last tool call: \(last.displayName) @ \(last.shortTime)")
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("No activity yet")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private var divider: some View {
        Divider().frame(height: 20)
    }

    private func pulseDot(color: Color, pulse: Bool) -> some View {
        ZStack {
            if pulse {
                Circle().fill(color.opacity(0.3)).frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 1.4 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            }
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .frame(width: 14, height: 14)
    }

    private func ollamaAction() {
        if !ollama.isOllamaRunning { ollama.launchOllama() }
        else if ollama.isModelLoaded { ollama.stopModel() }
        else { ollama.startModel() }
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

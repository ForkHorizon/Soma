import SwiftUI

struct GlobalSettingsBar: View {
    @ObservedObject var viewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager

    var body: some View {
        HStack(spacing: 20) {
            // Project Section
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Project Root")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(viewModel.selectedProjectRoot.isEmpty ? "None" : (viewModel.selectedProjectRoot as NSString).lastPathComponent)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                }
                Button("Change") {
                    chooseProjectRoot()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            
            Divider().frame(height: 24)

            // MCP Section
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.somaServerRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text("MCP Gateway")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(viewModel.somaServerRunning ? "Online" : "Offline")
                        .font(.subheadline.bold())
                }
                Button(viewModel.somaServerRunning ? "Stop" : "Start") {
                    if viewModel.somaServerRunning {
                        viewModel.stopSomaServer()
                    } else {
                        viewModel.startSomaServer()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.somaServerBusy || viewModel.selectedProjectRoot.isEmpty)
            }

            Divider().frame(height: 24)

            // Ollama Section
            HStack(spacing: 8) {
                Circle()
                    .fill(ollama.isOllamaRunning ? (ollama.isModelLoaded ? Color.green : Color.orange) : Color.red)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Local AI")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(ollama.isOllamaRunning ? (ollama.isModelLoaded ? "Ready" : "Idle") : "Offline")
                        .font(.subheadline.bold())
                }
                Button(action: ollamaAction) {
                    if ollama.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(ollama.isOllamaRunning ? (ollama.isModelLoaded ? "Stop" : "Start") : "Launch")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(ollama.isBusy)
            }
            
            Spacer()
            
            // Nexus Status (Visual only)
            HStack(spacing: 4) {
                Image(systemName: "circle.grid.3x3.fill")
                    .foregroundColor(viewModel.nexusConnected ? .blue : .secondary)
                Text("Nexus")
                    .font(.caption)
                    .foregroundColor(viewModel.nexusConnected ? .primary : .secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
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

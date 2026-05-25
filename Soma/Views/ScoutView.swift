import AppKit
import SwiftUI

struct ScoutView: View {
    @ObservedObject var viewModel: ScoutViewModel
    @ObservedObject var somaViewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                SomaPage {
                    WorkflowHeader(
                        title: "Scout Files",
                        subtitle: "Optional exploration mode using the Scout model \(ollama.modelName). Use Prepare Packet when you want a compact handoff for another model.",
                        icon: "folder.badge.magnifyingglass",
                        tone: .info
                    )

                    if !ollama.isOllamaRunning {
                        StatusBanner(
                            title: "Local AI is offline",
                            detail: "Scout depends on Ollama because it chats directly with \(ollama.modelName). Launch Local AI from the top bar to use this screen.",
                            tone: .warning
                        )
                    } else if !ollama.isModelLoaded {
                        StatusBanner(
                            title: "Model is not loaded yet",
                            detail: "Ollama is running. Load \(ollama.modelName) from the top bar before asking Scout to inspect files.",
                            tone: .info
                        )
                    }

                    if viewModel.scoutTranscript.isEmpty {
                        SomaPanel(title: "Optional Explorer", subtitle: "Use this when you want a direct local-model conversation with project files.", icon: "folder.badge.magnifyingglass", tone: .info) {
                            EmptyStateView(
                                icon: "folder.badge.magnifyingglass",
                                title: "Ask focused file questions",
                                subtitle: "Examples: find the auth entrypoint, explain recent errors, inspect a suspected file, or summarize how a feature is wired."
                            )
                        }
                    } else {
                        transcriptPanel
                    }

                    if viewModel.scoutLoading {
                        StatusBanner(
                            title: "Scout is reading context",
                            detail: "Soma is calling the local scout pipeline and will append the answer to the transcript.",
                            tone: .warning,
                            isLoading: true
                        )
                        .id("loading")
                    }
                }
                .onChange(of: viewModel.scoutTranscript) { _, _ in
                    proxy.scrollTo("loading", anchor: .bottom)
                }
            }

            PromptInputBar(
                text: $viewModel.scoutPrompt,
                placeholder: "Ask Soma to find, read, or explain files in the selected project...",
                buttonLabel: "Scout Files",
                icon: "magnifyingglass",
                disabled: viewModel.scoutLoading || !ollama.isOllamaRunning || !ollama.isModelLoaded,
                disabledReason: scoutDisabledReason,
                minHeight: 52,
                onClear: { viewModel.resetState() }
            ) {
                viewModel.runScout(ollama: ollama, somaViewModel: somaViewModel)
            }
        }
    }

    private var scoutDisabledReason: String? {
        if viewModel.scoutLoading {
            return "Scout is already working."
        }
        if !ollama.isOllamaRunning {
            return "Launch Local AI in the top bar first."
        }
        if !ollama.isModelLoaded {
            return "Load the local model in the top bar first."
        }
        return nil
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Scout Transcript", systemImage: "text.bubble")
                    .font(.headline)
                Spacer()
                Button {
                    copyToClipboard(viewModel.scoutTranscript)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(viewModel.scoutTranscript)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
                .background(Color(NSColor.textBackgroundColor).opacity(0.80))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }
}

import SwiftUI
import AppKit

struct ScoutView: View {
    @ObservedObject var viewModel: ScoutViewModel
    @ObservedObject var somaViewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if viewModel.scoutTranscript.isEmpty {
                            emptyState(icon: "folder.badge.magnifyingglass", title: "Scout mode", subtitle: "Chat directly with \(ollama.modelName) to explore your files")
                        } else {
                            Text(viewModel.scoutTranscript).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                        if viewModel.scoutLoading {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Soma is scouting…").foregroundColor(.secondary).italic()
                            }.id("loading")
                        }
                    }.padding()
                }
                .background(Color(NSColor.textBackgroundColor).opacity(0.5)).cornerRadius(8).padding(.horizontal)
                .onChange(of: viewModel.scoutTranscript) { _, _ in proxy.scrollTo("loading", anchor: .bottom) }
            }
            inputBar(text: $viewModel.scoutPrompt, placeholder: "Ask Soma to find or read files…", disabled: viewModel.scoutLoading || !ollama.isOllamaRunning, buttonLabel: "Scout Files", icon: "magnifyingglass") {
                viewModel.runScout(ollama: ollama, somaViewModel: somaViewModel)
            }
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer(minLength: 60)
            Image(systemName: icon).font(.system(size: 44)).foregroundColor(.secondary.opacity(0.4))
            Text(title).font(.title3).bold()
            Text(subtitle).foregroundColor(.secondary).multilineTextAlignment(.center)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func inputBar(text: Binding<String>, placeholder: String, disabled: Bool, buttonLabel: String, icon: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty { Text(placeholder).foregroundColor(.secondary).padding(.leading, 5).padding(.top, 8).font(.body).allowsHitTesting(false).accessibilityHidden(true) }
                TextEditor(text: text).font(.body).frame(minHeight: 60, maxHeight: 100).padding(4).background(Color.clear)
                    .accessibilityLabel(Text(placeholder))
                    .onSubmit { if !disabled { action() } }
            }.background(Color(NSColor.controlBackgroundColor)).cornerRadius(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
            HStack {
                Spacer()
                Button(action: action) { HStack { Image(systemName: icon); Text(buttonLabel) }.bold().padding(.horizontal, 8) }
                    .buttonStyle(BorderedProminentButtonStyle())
                    .controlSize(.regular)
                    .disabled(disabled || text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(disabled ? "Currently unavailable" : (text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter a prompt to continue" : "Submit (⌘ ↵)"))
            }
        }.padding()
    }
}

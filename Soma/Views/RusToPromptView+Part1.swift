import SwiftUI

extension RusToPromptView {
    var topBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Label("Rus to Prompt", systemImage: "character.bubble")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.primary)

                phasePill

                Spacer(minLength: 12)

                transformButton
            }

            HStack(spacing: 10) {
                Toggle(
                    "Auto benchmark",
                    isOn: Binding(
                        get: { queueManager.settings.autoEnqueueEnabled },
                        set: { queueManager.setAutoEnqueueEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("After a successful Rus to Prompt transform, enqueue the real Russian prompt for local staged benchmarking.")

                Button {
                    showModels.toggle()
                    if showModels {
                        loadRusToPromptModelStatsIfNeeded()
                    }
                } label: {
                    Label("Models", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: $showModels, arrowEdge: .bottom) {
                    modelPopover
                }

                Button {
                    if ollama.isOllamaRunning {
                        ollama.refreshInstalledModels()
                        ollama.checkStatus()
                    } else {
                        ollama.launchOllama()
                    }
                } label: {
                    Label(
                        ollama.isOllamaRunning ? "Refresh" : "Launch",
                        systemImage: ollama.isOllamaRunning ? "arrow.clockwise" : "play.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(ollama.isBusy)

                Text(phaseDetail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }

    var transformButton: some View {
        Button {
            copied = false
            selectedOutput = .improved
            viewModel.transform(somaViewModel: somaViewModel, ollama: ollama, queueManager: queueManager)
        } label: {
            if viewModel.isBusy {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text(busyButtonTitle)
                }
                .bold()
            } else {
                Label("Transform", systemImage: "wand.and.stars")
                    .bold()
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(transformDisabled)
        .keyboardShortcut(.return, modifiers: .command)
        .help(transformDisabled ? transformDisabledReason : "Transform prompt")
    }

    var inputPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Input")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.inputPrompt.count) chars")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Clear") {
                    copied = false
                    viewModel.resetState()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ZStack(alignment: .topLeading) {
                if viewModel.inputPrompt.isEmpty {
                    Text("Paste Russian prompt...")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.top, 11)
                        .padding(.leading, 9)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $viewModel.inputPrompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .background(Color.clear)
                    .accessibilityLabel("Russian prompt input")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor).opacity(0.86))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.20)))
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity, alignment: .topLeading)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    var outputPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Output", selection: $selectedOutput) {
                    ForEach(RusToPromptOutputTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(minWidth: 230, maxWidth: 360)

                Spacer()

                Button {
                    copyToClipboard(viewModel.finalPromptForCopy)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.finalPromptForCopy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            statusLine

            outputTextView
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity, alignment: .topLeading)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    var statusLine: some View {
        HStack(spacing: 8) {
            if viewModel.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: phaseIcon)
                    .foregroundColor(phaseTone.color)
            }
            Text(phaseTitle)
                .font(.caption.bold())
                .foregroundColor(phaseTone.color)
            Text(phaseDetail)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let confidence = viewModel.confidenceResult?.confidence {
                StatusChip(text: String(format: "%.0f%%", confidence * 100), tone: confidenceTone(confidence))
                    .help(
                        "Confidence score from \(viewModel.confidenceResult?.model ?? viewModel.confidenceModel), reasoning \(viewModel.confidenceResult?.reasoningEffort ?? RusToPromptSettingsStore.defaultConfidenceReasoning)"
                    )
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 22)
    }

    var outputTextView: some View {
        ScrollView {
            Text(outputText.isEmpty ? emptyOutputText : outputText)
                .font(.system(.body, design: outputText.isEmpty ? .default : .monospaced))
                .foregroundColor(outputText.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor).opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.20)))
    }

}

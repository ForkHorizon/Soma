import SwiftUI

extension RusToPromptView {
    var modelPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Models")
                    .font(.headline)
                Spacer()
                StatusChip(text: ollama.isOllamaRunning ? "Ollama online" : "Ollama offline", tone: ollama.isOllamaRunning ? .good : .warning)
            }

            HStack(alignment: .top, spacing: 14) {
                presetSection(
                    title: "Translator",
                    selection: Binding(
                        get: { viewModel.translatorModel },
                        set: { viewModel.translatorModel = $0 }
                    ),
                    presets: RusToPromptViewModel.translatorPresets
                )

                Divider()
                    .frame(height: 310)

                presetSection(
                    title: "Analyzer",
                    selection: Binding(
                        get: { viewModel.analyzerModel },
                        set: { viewModel.analyzerModel = $0 }
                    ),
                    presets: RusToPromptViewModel.analyzerPresets,
                    requiresOllama: true
                )

                Divider()
                    .frame(height: 310)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Run confidence", isOn: $viewModel.confidenceEnabled)
                        .font(.subheadline.bold())
                    presetSection(
                        title: "Confidence",
                        selection: Binding(
                            get: { viewModel.confidenceModel },
                            set: { viewModel.confidenceModel = $0 }
                        ),
                        presets: RusToPromptViewModel.confidencePresets,
                        requiresOllama: false
                    )
                }
            }
        }
        .padding(14)
        .frame(width: 1040)
    }


    func presetSection(title: String, selection: Binding<String>, presets: [RusToPromptModelPreset], requiresOllama: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.bold())
            ForEach(presets) { preset in
                presetRow(preset, selection: selection, requiresOllama: requiresOllama)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }


    func presetRow(_ preset: RusToPromptModelPreset, selection: Binding<String>, requiresOllama: Bool) -> some View {
        let selected = selection.wrappedValue == preset.model
        let usesCodex = preset.isCodex
        let installed = usesCodex || !requiresOllama || isInstalled(preset.model)

        return Button {
            selection.wrappedValue = preset.model
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selected ? .accentColor : .secondary)
                    Text(preset.model)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if preset.recommended {
                        StatusChip(text: "Recommended", tone: .good)
                    }
                    if !installed {
                        StatusChip(text: "Missing", tone: .warning)
                    } else if usesCodex || !requiresOllama {
                        StatusChip(text: "Codex", tone: .info)
                    }
                }

                HStack(spacing: 6) {
                    StatusChip(text: "Quality \(preset.quality)", tone: qualityTone(preset.quality))
                    StatusChip(text: "Speed \(preset.speed)", tone: speedTone(preset.speed))
                    StatusChip(text: preset.ram, tone: .neutral)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.12) : Color(NSColor.textBackgroundColor).opacity(0.64))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(preset.detail)
    }


    var phasePill: some View {
        HStack(spacing: 7) {
            if viewModel.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: phaseIcon)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(phaseTitle)
                .lineLimit(1)
            Text(activeModelLabel)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption.bold())
        .foregroundColor(phaseTone.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(phaseTone.color.opacity(0.10))
        .clipShape(Capsule())
        .frame(maxWidth: 360, alignment: .leading)
    }


    var outputText: String {
        switch selectedOutput {
        case .improved:
            return viewModel.finalPromptForCopy
        case .translation:
            return viewModel.translation
        case .confidence:
            return confidenceOutputText
        }
    }


    var emptyOutputText: String {
        switch viewModel.phase {
        case .idle:
            return "Result will appear here."
        case .translating:
            return "Translating..."
        case .analyzing:
            return selectedOutput == .translation ? viewModel.translation : "Analyzing..."
        case .checkingConfidence:
            return selectedOutput == .confidence ? "Checking confidence..." : outputText.isEmpty ? "Checking confidence..." : outputText
        case .done, .degraded, .failed:
            if selectedOutput == .translation { return "No translation returned." }
            if selectedOutput == .confidence { return "No confidence score returned." }
            return "No improved prompt returned."
        }
    }


    var transformDisabled: Bool {
        viewModel.isBusy || !ollama.isOllamaRunning || viewModel.inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }


    var transformDisabledReason: String {
        if viewModel.isBusy { return "Rus to Prompt is already running." }
        if !ollama.isOllamaRunning { return "Launch Ollama first." }
        return "Enter a prompt."
    }


    var phaseTitle: String {
        if !ollama.isOllamaRunning && !viewModel.isBusy { return "Offline" }
        switch viewModel.phase {
        case .idle: return "Ready"
        case .translating: return "Translating"
        case .analyzing: return "Analyzing"
        case .checkingConfidence: return "Confidence"
        case .done: return "Done"
        case .degraded: return "Fallback"
        case .failed: return "Failed"
        }
    }


    var phaseDetail: String {
        if let error = viewModel.errorMessage, viewModel.phase == .failed { return error }
        if let warning = viewModel.warningMessage, viewModel.phase == .degraded { return warning }
        switch viewModel.phase {
        case .idle:
            let confidence = viewModel.confidenceEnabled ? " | Confidence \(shortModelName(viewModel.confidenceModel))" : ""
            return "Translator \(shortModelName(viewModel.translatorModel)) | Analyzer \(shortModelName(viewModel.analyzerModel))\(confidence)"
        case .translating:
            return viewModel.translatorModel
        case .analyzing:
            return viewModel.analyzerModel
        case .checkingConfidence:
            return viewModel.confidenceModel
        case .done:
            if let confidence = viewModel.confidenceResult?.confidence {
                return String(format: "Improved prompt ready | confidence %.0f%%", confidence * 100)
            }
            if let warning = viewModel.confidenceWarning { return warning }
            return "Improved prompt ready"
        case .degraded:
            if let confidence = viewModel.confidenceResult?.confidence {
                return String(format: "Using fallback | confidence %.0f%%", confidence * 100)
            }
            return viewModel.confidenceWarning ?? "Using translation as fallback"
        case .failed:
            return "No result"
        }
    }

}

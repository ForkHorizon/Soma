import AppKit
import SwiftUI

private enum RusToPromptOutputTab: String, CaseIterable, Identifiable {
    case improved = "Improved"
    case translation = "Translation"
    case confidence = "Confidence"

    var id: String { rawValue }
}

struct RusToPromptView: View {
    @ObservedObject var viewModel: RusToPromptViewModel
    @ObservedObject var somaViewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager
    @ObservedObject var queueManager: RusToPromptQueueManager
    @State private var selectedOutput: RusToPromptOutputTab = .improved
    @State private var showModels = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(alignment: .top, spacing: 14) {
                inputPane
                outputPane
            }
            .padding(16)
            .frame(maxHeight: .infinity)
        }
        .background(SomaDesign.pageBackground)
        .onAppear {
            ollama.refreshInstalledModels()
            ollama.checkStatus()
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Label("Rus to Prompt", systemImage: "character.bubble")
                .font(.title3.weight(.semibold))
                .foregroundColor(.primary)

            phasePill

            Spacer(minLength: 12)

            Toggle("Auto benchmark", isOn: Binding(
                get: { queueManager.settings.autoEnqueueEnabled },
                set: { queueManager.setAutoEnqueueEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("After a successful Rus to Prompt transform, enqueue the real Russian prompt for local staged benchmarking.")

            Button {
                showModels.toggle()
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
                Label(ollama.isOllamaRunning ? "Refresh" : "Launch", systemImage: ollama.isOllamaRunning ? "arrow.clockwise" : "play.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(ollama.isBusy)

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
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var inputPane: some View {
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
        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Output", selection: $selectedOutput) {
                    ForEach(RusToPromptOutputTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 330)

                Spacer()

                Button {
                    copyToClipboard(viewModel.finalPromptForCopy)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy Improved", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.finalPromptForCopy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            statusLine

            outputTextView
        }
        .padding(14)
        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    private var statusLine: some View {
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
                    .help("Confidence score from \(viewModel.confidenceResult?.model ?? viewModel.confidenceModel), reasoning \(viewModel.confidenceResult?.reasoningEffort ?? RusToPromptSettingsStore.defaultConfidenceReasoning)")
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 22)
    }

    private var outputTextView: some View {
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

    private var modelPopover: some View {
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

    private func presetSection(title: String, selection: Binding<String>, presets: [RusToPromptModelPreset], requiresOllama: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.bold())
            ForEach(presets) { preset in
                presetRow(preset, selection: selection, requiresOllama: requiresOllama)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func presetRow(_ preset: RusToPromptModelPreset, selection: Binding<String>, requiresOllama: Bool) -> some View {
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

    private var phasePill: some View {
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

    private var outputText: String {
        switch selectedOutput {
        case .improved:
            return viewModel.finalPromptForCopy
        case .translation:
            return viewModel.translation
        case .confidence:
            return confidenceOutputText
        }
    }

    private var emptyOutputText: String {
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

    private var transformDisabled: Bool {
        viewModel.isBusy || !ollama.isOllamaRunning || viewModel.inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var transformDisabledReason: String {
        if viewModel.isBusy { return "Rus to Prompt is already running." }
        if !ollama.isOllamaRunning { return "Launch Ollama first." }
        return "Enter a prompt."
    }

    private var phaseTitle: String {
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

    private var phaseDetail: String {
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

    private var activeModelLabel: String {
        switch viewModel.phase {
        case .translating:
            return shortModelName(viewModel.translatorModel)
        case .analyzing:
            return shortModelName(viewModel.analyzerModel)
        case .checkingConfidence:
            return shortModelName(viewModel.confidenceModel)
        default:
            return ""
        }
    }

    private var phaseIcon: String {
        switch viewModel.phase {
        case .idle: return ollama.isOllamaRunning ? "checkmark.circle" : "exclamationmark.triangle.fill"
        case .translating: return "text.bubble"
        case .analyzing: return "brain"
        case .checkingConfidence: return "gauge.with.dots.needle.50percent"
        case .done: return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var phaseTone: SomaStatusTone {
        if !ollama.isOllamaRunning && !viewModel.isBusy { return .warning }
        switch viewModel.phase {
        case .idle: return .neutral
        case .translating, .analyzing, .checkingConfidence: return .info
        case .done: return .good
        case .degraded: return .warning
        case .failed: return .danger
        }
    }

    private var busyButtonTitle: String {
        switch viewModel.phase {
        case .translating: return "Translating"
        case .analyzing: return "Analyzing"
        case .checkingConfidence: return "Checking"
        default: return "Working"
        }
    }

    private var confidenceOutputText: String {
        guard let result = viewModel.confidenceResult else {
            return viewModel.confidenceWarning ?? ""
        }
        var lines: [String] = []
        if let confidence = result.confidence {
            lines.append(String(format: "Confidence: %.0f%%", confidence * 100))
        }
        if let verdict = result.verdict {
            lines.append("Verdict: \(verdict)")
        }
        lines.append("Model: \(result.model ?? viewModel.confidenceModel)")
        lines.append("Reasoning: \(result.reasoningEffort ?? RusToPromptSettingsStore.defaultConfidenceReasoning)")
        if let status = result.status {
            lines.append("Status: \(status)")
        }
        if let scores = result.scores, !scores.isEmpty {
            lines.append("")
            lines.append("Scores:")
            for key in scores.keys.sorted() {
                lines.append("- \(key): \(scores[key] ?? 0)/5")
            }
        }
        let warnings = result.warnings?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        if !warnings.isEmpty {
            lines.append("")
            lines.append("Warnings:")
            lines.append(contentsOf: warnings.map { "- \($0)" })
        }
        let notes = result.notes?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        if !notes.isEmpty {
            lines.append("")
            lines.append("Notes:")
            lines.append(contentsOf: notes.map { "- \($0)" })
        }
        if let error = result.error, !error.isEmpty {
            lines.append("")
            lines.append("Error: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    private func isInstalled(_ model: String) -> Bool {
        ollama.installedModels.contains { $0.name.lowercased() == model.lowercased() }
    }

    private func qualityTone(_ quality: String) -> SomaStatusTone {
        switch quality {
        case "Best", "High": return .good
        case "Good": return .info
        default: return .neutral
        }
    }

    private func speedTone(_ speed: String) -> SomaStatusTone {
        switch speed {
        case "Fast", "Fastest": return .good
        case "Balanced", "Medium": return .info
        default: return .warning
        }
    }

    private func confidenceTone(_ confidence: Double) -> SomaStatusTone {
        if confidence >= 0.90 { return .good }
        if confidence >= 0.75 { return .info }
        if confidence >= 0.50 { return .warning }
        return .danger
    }

    private func shortModelName(_ model: String) -> String {
        if model.count <= 30 { return model }
        return String(model.prefix(27)) + "..."
    }
}

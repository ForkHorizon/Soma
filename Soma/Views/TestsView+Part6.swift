import SwiftUI
import AppKit
import Foundation

extension TestsView {
    func modelToggleRow(
        _ row: TestRankedModelPreset,
        selection: Binding<Set<String>>,
        storageKey: String
    ) -> some View {
        let preset = row.preset
        return Toggle(
            isOn: Binding(
                get: { selection.wrappedValue.contains(preset.model) },
                set: { enabled in
                    if enabled {
                        selection.wrappedValue.insert(preset.model)
                    } else {
                        selection.wrappedValue.remove(preset.model)
                    }
                    saveModelSelection(selection.wrappedValue, key: storageKey)
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(preset.model)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if preset.recommended {
                        StatusChip(text: "Recommended", tone: .good)
                    }
                    if preset.isCodex {
                        StatusChip(text: "Codex", tone: .info)
                    }
                    if preset.isGemini {
                        StatusChip(text: "Gemini", tone: .info)
                    }
                    if preset.isDeepSeek {
                        StatusChip(text: "DeepSeek", tone: .info)
                        StatusChip(text: "Paid API", tone: .warning)
                    }
                    if let decision = modelScopeDecisionChip(row.stats) {
                        StatusChip(text: decision.text, tone: decision.tone)
                    }
                    StatusChip(text: "Q \(row.quality)", tone: qualityTone(row.quality))
                    StatusChip(text: "S \(row.speed)", tone: speedTone(row.speed))
                    StatusChip(text: preset.ram, tone: .neutral)
                }
                modelScopeSummary(row.stats)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color(NSColor.textBackgroundColor).opacity(0.64))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
        .help(modelScopeHelp(preset: preset, stats: row.stats))
    }

    var confidencePanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Confidence checker")
                        .font(.subheadline.bold())
                    StatusChip(text: selectedConfidenceProviderLabel, tone: .info)
                }
                Text(selectedConfidenceDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Menu {
                ForEach([1, 5, 10, 20], id: \.self) { size in
                    Button {
                        selectedConfidenceBatchSize = size
                        saveConfidenceBatchSize(size)
                    } label: {
                        HStack {
                            if selectedConfidenceBatchSize == size {
                                Image(systemName: "checkmark")
                            }
                            Text(size == 1 ? "No batching" : "Batch \(size)")
                        }
                    }
                    .help(
                        size == 1
                            ? "Run every confidence check as its own request."
                            : "Batch up to \(size) improver results that share one source prompt and translator.")
                }
            } label: {
                Label("Batch \(selectedConfidenceBatchSize)", systemImage: "square.stack.3d.up")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)

            Toggle(
                "Local gate",
                isOn: Binding(
                    get: { useHybridConfidence },
                    set: { enabled in
                        useHybridConfidence = enabled
                        saveHybridConfidence(enabled)
                    }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(
                "Run two local Ollama confidence judges first. The selected online model is used only when local judges fail, disagree, or report low confidence."
            )

            Button {
                showLocalConfidenceModels.toggle()
            } label: {
                Label("Local \(selectedLocalConfidenceModels.count)/2", systemImage: "desktopcomputer")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popover(isPresented: $showLocalConfidenceModels, arrowEdge: .bottom) {
                localConfidenceModelsPopover
            }
            .help("Choose exactly two local Ollama models for the first confidence pass.")

            Menu {
                ForEach(confidenceModelPresetsForMenu) { preset in
                    Button {
                        selectedConfidenceModel = preset.model
                        saveConfidenceModel(preset.model)
                    } label: {
                        HStack {
                            if selectedConfidenceModel == preset.model {
                                Image(systemName: "checkmark")
                            }
                            Text(preset.model)
                        }
                    }
                    .help(preset.detail)
                }
            } label: {
                Label("Choose", systemImage: "chevron.down.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    var localConfidenceModelsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Local confidence judges")
                    .font(.headline)
                StatusChip(
                    text: "\(selectedLocalConfidenceModels.count)/2 selected",
                    tone: selectedLocalConfidenceModels.count == 2 ? .good : .warning)
                Spacer()
                Button {
                    ollama.refreshInstalledModels()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            Text(
                "The two local judges run first. The selected online fallback checks only cases with local failure, confidence below 0.80, or disagreement above 0.15."
            )
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(localConfidenceModelPresets) { preset in
                        localConfidenceModelRow(preset)
                    }
                }
            }
            .frame(maxHeight: 340)
        }
        .padding(12)
        .frame(width: 460)
    }

    func localConfidenceModelRow(_ preset: RusToPromptModelPreset) -> some View {
        let selected = selectedLocalConfidenceModels.contains(preset.model)
        return Button {
            toggleLocalConfidenceModel(preset.model)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundColor(selected ? .accentColor : .secondary)
                Text(preset.model)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if preset.recommended {
                    StatusChip(text: "Recommended", tone: .good)
                }
                StatusChip(text: preset.ram.isEmpty ? "Local" : preset.ram, tone: .neutral)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color(NSColor.textBackgroundColor).opacity(selected ? 0.9 : 0.64))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.12)))
        .help(preset.detail)
    }

}

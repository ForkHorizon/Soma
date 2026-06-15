import SwiftUI
import AppKit
import Foundation

extension TestsView {
    var queueConfidencePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Confidence")
                    .font(.subheadline.bold())
                StatusChip(text: queueConfidenceModeLabel, tone: queueManager.settings.confidenceReferee == "off" ? .neutral : .info)
                Spacer()
            }

            Text(queueConfidenceDescription)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    showQueueLocalConfidenceModels.toggle()
                } label: {
                    Label("Local \(queueManager.settings.localConfidenceModels.count)/2", systemImage: "desktopcomputer")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: $showQueueLocalConfidenceModels, arrowEdge: .bottom) {
                    queueLocalConfidenceModelsPopover
                }
                .help("Choose up to two local Ollama judges. Two selected local judges enable the local confidence gate.")

                Picker("Online fallback", selection: Binding(
                    get: { queueConfidenceFallbackReferee },
                    set: { setQueueConfidenceFallbackReferee($0) }
                )) {
                    Text("Off").tag("off")
                    Text("Gemini").tag("gemini")
                    Text("Codex").tag("codex")
                    Text("DeepSeek").tag("deepseek")
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Menu {
                    ForEach(queueOnlineConfidencePresets) { preset in
                        Button(preset.model) {
                            setQueueOnlineConfidenceModel(preset.model)
                        }
                        .help(preset.detail)
                    }
                } label: {
                    Label(shortModelName(queueManager.settings.confidenceModel), systemImage: "cloud")
                }
                .menuStyle(.button)
                .disabled(queueConfidenceFallbackReferee == "off")
            }

            Picker("Batch", selection: Binding(
                get: { queueManager.settings.confidenceBatchSize },
                set: {
                    queueManager.updateConfidence(
                        referee: queueManager.settings.confidenceReferee,
                        model: queueManager.settings.confidenceModel,
                        localModels: queueManager.settings.localConfidenceModels,
                        hybridGeminiModel: queueManager.settings.hybridGeminiModel,
                        hybridFallbackReferee: queueManager.settings.hybridFallbackReferee ?? queueConfidenceFallbackReferee,
                        batchSize: $0
                    )
                }
            )) {
                Text("1").tag(1)
                Text("5").tag(5)
                Text("10").tag(10)
                Text("20").tag(20)
            }
            .pickerStyle(.segmented)
        }
    }


    var queueConfidenceFallbackReferee: String {
        let stored = queueManager.settings.hybridFallbackReferee ?? ""
        if ["off", "gemini", "codex", "deepseek"].contains(stored) {
            return stored
        }
        if queueManager.settings.confidenceReferee == "gemini" || queueManager.settings.confidenceReferee == "codex" || queueManager.settings.confidenceReferee == "deepseek" {
            return queueManager.settings.confidenceReferee
        }
        let model = queueManager.settings.confidenceModel
        return providerForOnlineModelName(model) ?? "off"
    }


    var queueConfidenceModeLabel: String {
        let localCount = queueManager.settings.localConfidenceModels.count
        let fallback = queueConfidenceFallbackReferee
        if localCount >= 2 {
            return fallback == "off" ? "Local x2" : "Local x2 + \(providerDisplayName(fallback))"
        }
        if localCount == 1 && fallback == "off" {
            return "Local"
        }
        if fallback == "off" {
            return "Off"
        }
        return providerDisplayName(fallback)
    }


    var queueConfidenceDescription: String {
        let locals = queueManager.settings.localConfidenceModels.prefix(2).joined(separator: " + ")
        let fallback = queueConfidenceFallbackReferee
        if queueManager.settings.localConfidenceModels.count >= 2 {
            let fallbackText = fallback == "off" ? "no online fallback" : "\(providerDisplayName(fallback)) fallback \(queueManager.settings.confidenceModel)"
            return "Local gate: \(locals). If local judges fail, disagree, or score low: \(fallbackText)."
        }
        if queueManager.settings.localConfidenceModels.count == 1 && fallback == "off" {
            return "Local-only confidence with \(queueManager.settings.localConfidenceModels[0]). Add a second local judge for safer agreement checks."
        }
        if fallback == "off" {
            return "Confidence is disabled. Translation gates and quality stats will not be scored."
        }
        return "Online-only confidence with \(providerDisplayName(fallback)) \(queueManager.settings.confidenceModel). Add two local judges to use a local gate before online fallback."
    }


    var queueOnlineConfidencePresets: [RusToPromptModelPreset] {
        switch queueConfidenceFallbackReferee {
        case "gemini":
            return RusToPromptViewModel.confidencePresets.filter { $0.isGemini }
        case "codex":
            return RusToPromptViewModel.confidencePresets.filter { $0.isCodex }
        case "deepseek":
            return RusToPromptViewModel.confidencePresets.filter { $0.isDeepSeek }
        default:
            return RusToPromptViewModel.confidencePresets
        }
    }


    var queueLocalConfidenceModelsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Local confidence judges")
                    .font(.headline)
                StatusChip(text: "\(queueManager.settings.localConfidenceModels.count)/2 selected", tone: queueManager.settings.localConfidenceModels.count == 2 ? .good : .warning)
                Spacer()
                Button {
                    ollama.refreshInstalledModels()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            Text("Pick two local Ollama models for the local gate. Online fallback is configured separately and can be Gemini, Codex, DeepSeek, or Off.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(localConfidenceModelPresets) { preset in
                        queueLocalConfidenceModelRow(preset)
                    }
                }
            }
            .frame(maxHeight: 340)
        }
        .padding(12)
        .frame(width: 500)
    }


    func queueLocalConfidenceModelRow(_ preset: RusToPromptModelPreset) -> some View {
        let selected = queueManager.settings.localConfidenceModels.contains(preset.model)
        return Button {
            var next = queueManager.settings.localConfidenceModels
            if let index = next.firstIndex(of: preset.model) {
                next.remove(at: index)
            } else {
                if next.count >= 2 {
                    next.removeFirst()
                }
                next.append(preset.model)
            }
            setQueueLocalConfidenceModels(next)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundColor(selected ? .accentColor : .secondary)
                Text(preset.model)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                StatusChip(text: isInstalled(preset.model) ? "Local" : "Missing", tone: isInstalled(preset.model) ? .neutral : .warning)
                if !preset.ram.isEmpty {
                    StatusChip(text: preset.ram, tone: .neutral)
                }
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

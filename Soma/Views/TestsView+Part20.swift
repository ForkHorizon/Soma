import SwiftUI
import AppKit
import Foundation

extension TestsView {
    func installedModelPresets(
        knownPresets: [RusToPromptModelPreset],
        extraModels: Set<String> = []
    ) -> [RusToPromptModelPreset] {
        let knownByName = knownPresetLookup(knownPresets)
        var seen = Set<String>()
        var presets = installedPresetRows(knownByName: knownByName, seen: &seen)
        appendKnownExternalPresets(knownPresets, to: &presets, seen: &seen)
        appendExtraModelPresets(extraModels, to: &presets, seen: &seen)
        return presets
    }


    func knownPresetLookup(_ knownPresets: [RusToPromptModelPreset]) -> [String: RusToPromptModelPreset] {
        var lookup: [String: RusToPromptModelPreset] = [:]
        for preset in knownPresets where lookup[preset.model.lowercased()] == nil {
            lookup[preset.model.lowercased()] = preset
        }
        return lookup
    }


    func installedPresetRows(
        knownByName: [String: RusToPromptModelPreset],
        seen: inout Set<String>
    ) -> [RusToPromptModelPreset] {
        ollama.installedModels.map { installed in
            seen.insert(installed.name.lowercased())
            if let known = knownByName[installed.name.lowercased()] {
                return mergedInstalledPreset(installed, known: known)
            }
            return RusToPromptModelPreset(
                model: installed.name,
                quality: "Unknown",
                speed: "Unknown",
                ram: installed.formattedSize.isEmpty ? installed.parameterSize : installed.formattedSize,
                detail: installed.displayDetail.isEmpty ? "Installed Ollama model." : installed.displayDetail,
                recommended: false
            )
        }
    }


    func mergedInstalledPreset(_ installed: OllamaInstalledModel, known: RusToPromptModelPreset) -> RusToPromptModelPreset {
        RusToPromptModelPreset(
            model: installed.name,
            quality: known.quality,
            speed: known.speed,
            ram: installed.formattedSize.isEmpty ? known.ram : installed.formattedSize,
            detail: known.detail,
            recommended: known.recommended,
            isCodex: known.isCodex,
            provider: known.provider
        )
    }


    func appendKnownExternalPresets(
        _ knownPresets: [RusToPromptModelPreset],
        to presets: inout [RusToPromptModelPreset],
        seen: inout Set<String>
    ) {
        for preset in knownPresets where preset.isCodex || preset.isGemini {
            let key = preset.model.lowercased()
            if !seen.contains(key) {
                presets.append(preset)
                seen.insert(key)
            }
        }
    }


    func appendExtraModelPresets(
        _ extraModels: Set<String>,
        to presets: inout [RusToPromptModelPreset],
        seen: inout Set<String>
    ) {
        for model in extraModels {
            let key = model.lowercased()
            if !seen.contains(key) {
                presets.append(adHocPreset(for: model))
                seen.insert(key)
            }
        }
    }


    func queueLocalModelRows(selected: [String]) -> [RusToPromptModelPreset] {
        let knownLocal = (RusToPromptViewModel.translatorPresets + RusToPromptViewModel.analyzerPresets)
            .filter { !$0.isCodex && !$0.isGemini && RusToPromptQueueManager.isLocalStageModel($0.model) }
        var rows = installedModelPresets(knownPresets: knownLocal)
            .filter { !$0.isCodex && !$0.isGemini && RusToPromptQueueManager.isLocalStageModel($0.model) }
        var seen = Set(rows.map { $0.model.lowercased() })
        for model in selected where !seen.contains(model.lowercased()) {
            rows.append(RusToPromptModelPreset(
                model: model,
                quality: "Unknown",
                speed: "Unknown",
                ram: "Missing",
                detail: "Selected queue model. Install it in Ollama before this queue can use it.",
                recommended: false
            ))
            seen.insert(model.lowercased())
        }
        return rows.sorted { lhs, rhs in
            let lhsSelected = selected.contains { $0.caseInsensitiveCompare(lhs.model) == .orderedSame }
            let rhsSelected = selected.contains { $0.caseInsensitiveCompare(rhs.model) == .orderedSame }
            if lhsSelected != rhsSelected { return lhsSelected }
            return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
        }
    }


    func queueItemTone(_ status: RusToPromptQueueItemStatus) -> SomaStatusTone {
        switch status {
        case .queued, .waitingLocalAI:
            return .info
        case .running:
            return .good
        case .completed:
            return .good
        case .failed, .blocked, .interrupted:
            return .warning
        }
    }


    func setQueueLocalConfidenceModels(_ models: [String]) {
        let clean = Array(models
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2))
        let fallback = queueConfidenceFallbackReferee
        let onlineModel = queueDefaultConfidenceModel(for: fallback, current: queueManager.settings.confidenceModel)
        queueManager.updateConfidence(
            referee: queueEffectiveConfidenceReferee(localModels: clean, fallbackReferee: fallback),
            model: queueConfidenceModelFor(localModels: clean, fallbackReferee: fallback, onlineModel: onlineModel),
            localModels: clean,
            hybridGeminiModel: onlineModel,
            hybridFallbackReferee: fallback,
            batchSize: queueManager.settings.confidenceBatchSize
        )
    }


    func setQueueConfidenceFallbackReferee(_ fallback: String) {
        let normalized = ["off", "gemini", "codex"].contains(fallback) ? fallback : "off"
        let localModels = queueManager.settings.localConfidenceModels
        let model = queueDefaultConfidenceModel(for: normalized, current: queueManager.settings.confidenceModel)
        queueManager.updateConfidence(
            referee: queueEffectiveConfidenceReferee(localModels: localModels, fallbackReferee: normalized),
            model: queueConfidenceModelFor(localModels: localModels, fallbackReferee: normalized, onlineModel: model),
            localModels: localModels,
            hybridGeminiModel: model,
            hybridFallbackReferee: normalized,
            batchSize: queueManager.settings.confidenceBatchSize
        )
    }


    func setQueueOnlineConfidenceModel(_ model: String) {
        let fallback = isGeminiModelName(model) ? "gemini" : "codex"
        let localModels = queueManager.settings.localConfidenceModels
        queueManager.updateConfidence(
            referee: queueEffectiveConfidenceReferee(localModels: localModels, fallbackReferee: fallback),
            model: queueConfidenceModelFor(localModels: localModels, fallbackReferee: fallback, onlineModel: model),
            localModels: localModels,
            hybridGeminiModel: model,
            hybridFallbackReferee: fallback,
            batchSize: queueManager.settings.confidenceBatchSize
        )
    }


    func queueEffectiveConfidenceReferee(localModels: [String], fallbackReferee: String) -> String {
        if localModels.count >= 2 { return "hybrid" }
        if fallbackReferee == "off" {
            return localModels.isEmpty ? "off" : "local"
        }
        return fallbackReferee
    }


    func queueConfidenceModelFor(localModels: [String], fallbackReferee: String, onlineModel: String? = nil) -> String {
        if localModels.count == 1 && fallbackReferee == "off" {
            return localModels[0]
        }
        return onlineModel ?? queueManager.settings.confidenceModel
    }


    func queueDefaultConfidenceModel(for fallbackReferee: String, current: String) -> String {
        switch fallbackReferee {
        case "gemini":
            if isGeminiModelName(current) { return current }
            return "gemini-3-flash-preview"
        case "codex":
            if isCodexModelName(current) { return current }
            return RusToPromptSettingsStore.defaultConfidence
        default:
            return current
        }
    }


    func isInstalled(_ model: String) -> Bool {
        ollama.installedModels.contains { $0.name.caseInsensitiveCompare(model) == .orderedSame }
    }


    func shortModelName(_ model: String) -> String {
        if model.count <= 30 { return model }
        return String(model.prefix(27)) + "..."
    }


    var localConfidenceModelPresets: [RusToPromptModelPreset] {
        let knownLocal = (RusToPromptViewModel.analyzerPresets + RusToPromptViewModel.translatorPresets)
            .filter { !$0.isCodex && !$0.isGemini }
        var presets = installedModelPresets(knownPresets: knownLocal)
            .filter { !$0.isCodex && !$0.isGemini }
        var seen = Set(presets.map { $0.model.lowercased() })
        let pinned = knownLocal + selectedLocalConfidenceModels.map {
            RusToPromptModelPreset(
                model: $0,
                quality: "Unknown",
                speed: "Unknown",
                ram: "Missing",
                detail: "Selected local confidence judge. Install it in Ollama if it is missing from the installed model list.",
                recommended: false
            )
        }
        for preset in pinned where !seen.contains(preset.model.lowercased()) {
            presets.append(preset)
            seen.insert(preset.model.lowercased())
        }
        return presets.sorted {
            if selectedLocalConfidenceModels.contains($0.model) != selectedLocalConfidenceModels.contains($1.model) {
                return selectedLocalConfidenceModels.contains($0.model)
            }
            return $0.model.localizedStandardCompare($1.model) == .orderedAscending
        }
    }


    func modelMenuLabel(_ preset: RusToPromptModelPreset) -> String {
        var parts = [
            preset.model,
            "Quality \(preset.quality)",
            "Speed \(preset.speed)",
            preset.ram
        ]
        if preset.recommended {
            parts.append("Recommended")
        }
        return parts.joined(separator: " | ")
    }

}

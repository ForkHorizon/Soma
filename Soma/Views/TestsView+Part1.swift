import SwiftUI
import AppKit
import Foundation

extension TestsView {
    var testTranslatorPresets: [RusToPromptModelPreset] {
        mergePresets(RusToPromptViewModel.translatorPresets + onlineStagePresets)
    }


    var testImproverPresets: [RusToPromptModelPreset] {
        mergePresets(RusToPromptViewModel.analyzerPresets + onlineStagePresets)
    }


    var onlineStagePresets: [RusToPromptModelPreset] {
        [
            RusToPromptModelPreset(model: "gpt-5.5", quality: "Best", speed: "Slow", ram: "0 GB", detail: "Codex GPT-5.5 via subscription. Highest-quality online stage model; use medium reasoning for bulk tests and high only for small samples.", recommended: false, isCodex: true),
            RusToPromptModelPreset(model: "gpt-5.4", quality: "Best", speed: "Slow", ram: "0 GB", detail: "Codex GPT-5.4 via subscription. Strong online stage model to compare against GPT-5.5 and mini.", recommended: false, isCodex: true),
            RusToPromptModelPreset(model: "gpt-5.4-mini", quality: "High", speed: "Medium", ram: "0 GB", detail: "Codex GPT-5.4-Mini via subscription. Good bulk online baseline with lower latency and lower expected usage pressure than frontier models.", recommended: false, isCodex: true),
            RusToPromptModelPreset(model: "gpt-5.3-codex", quality: "High", speed: "Medium", ram: "0 GB", detail: "Codex-specialized model. Useful to test prompt-improvement and code-heavy wording against standard GPT models.", recommended: false, isCodex: true),
            RusToPromptModelPreset(model: "gpt-5.3-codex-spark", quality: "Good", speed: "Medium", ram: "0 GB", detail: "Codex Spark model. Useful as a cheaper/faster Codex-flavored candidate; default catalog reasoning is high, but Soma passes medium for test stages.", recommended: false, isCodex: true),
            RusToPromptModelPreset(model: "gpt-5.2", quality: "Good", speed: "Medium", ram: "0 GB", detail: "Older Codex-accessible GPT model. Keep it for regression comparison against newer GPT/Codex models.", recommended: false, isCodex: true),
            RusToPromptModelPreset(model: "codex-auto-review", quality: "Good", speed: "Medium", ram: "0 GB", detail: "Codex auto-review model from the local Codex catalog. Mostly useful as an experimental judge/improver comparison.", recommended: false, isCodex: true),
            RusToPromptModelPreset(model: "deepseek-v4-flash", quality: "High", speed: "Fast", ram: "Paid API", detail: "DeepSeek paid API Flash model. Lower-cost default DeepSeek option for stage and confidence comparisons.", recommended: false, provider: "deepseek"),
            RusToPromptModelPreset(model: "deepseek-v4-pro", quality: "Best", speed: "Medium", ram: "Paid API", detail: "DeepSeek paid API Pro model. Use for higher-quality stage and confidence comparisons when token cost is acceptable.", recommended: false, provider: "deepseek"),
            RusToPromptModelPreset(model: "gemini-3-flash-preview", quality: "High", speed: "Medium", ram: "0 GB", detail: "Gemini CLI Flash candidate. Best first Gemini option for bulk translation/improvement tests while using your Google One AI Pro quota.", recommended: false, provider: "gemini"),
            RusToPromptModelPreset(model: "gemini-3-pro-preview", quality: "Best", speed: "Slow", ram: "0 GB", detail: "Gemini CLI Pro candidate. Use for smaller quality samples or hard cases before running a full sweep.", recommended: false, provider: "gemini"),
            RusToPromptModelPreset(model: "gemini-3.1-pro-preview", quality: "Best", speed: "Slow", ram: "0 GB", detail: "Gemini CLI Pro preview candidate. Strong quality option when speed and quota pressure are less important.", recommended: false, provider: "gemini"),
            RusToPromptModelPreset(model: "gemini-3.1-flash-lite-preview", quality: "Good", speed: "Fast", ram: "0 GB", detail: "Gemini CLI Flash Lite candidate. Use for high-volume sweeps when approximate ranking is enough.", recommended: false, provider: "gemini"),
            RusToPromptModelPreset(model: "gemini-2.5-pro", quality: "High", speed: "Slow", ram: "0 GB", detail: "Stable Gemini Pro fallback for quality checks if Gemini 3 preview models are unavailable.", recommended: false, provider: "gemini"),
            RusToPromptModelPreset(model: "gemini-2.5-flash", quality: "Good", speed: "Medium", ram: "0 GB", detail: "Stable Gemini Flash fallback for broad tests.", recommended: false, provider: "gemini"),
            RusToPromptModelPreset(model: "gemini-2.5-flash-lite", quality: "Good", speed: "Fast", ram: "0 GB", detail: "Stable Gemini Flash Lite fallback for high-volume runs.", recommended: false, provider: "gemini")
        ]
    }


    var selectedConfidencePreset: RusToPromptModelPreset? {
        RusToPromptViewModel.confidencePresets.first { $0.model == selectedConfidenceModel }
    }


    var hybridConfidenceActive: Bool {
        useHybridConfidence && selectedLocalConfidenceModels.count >= 2
    }


    var effectiveConfidenceWorkers: Int {
        hybridConfidenceActive ? 1 : confidenceWorkers
    }


    var hybridGeminiFallbackModel: String {
        selectedConfidenceModel
    }


    var confidenceModelPresetsForMenu: [RusToPromptModelPreset] {
        RusToPromptViewModel.confidencePresets
    }


    var selectedConfidenceFallbackReferee: String {
        if selectedConfidencePreset?.isDeepSeek == true { return "deepseek" }
        if selectedConfidencePreset?.isGemini == true { return "gemini" }
        return providerForOnlineModelName(selectedConfidenceModel) ?? "codex"
    }


    var selectedConfidenceReferee: String {
        if hybridConfidenceActive { return "hybrid" }
        if selectedConfidencePreset?.isDeepSeek == true { return "deepseek" }
        if selectedConfidencePreset?.isGemini == true { return "gemini" }
        return providerForOnlineModelName(selectedConfidenceModel) ?? "codex"
    }


    var selectedConfidenceProviderLabel: String {
        if hybridConfidenceActive { return "Local + \(providerDisplayName(selectedConfidenceFallbackReferee))" }
        if selectedConfidencePreset?.isDeepSeek == true { return "DeepSeek" }
        return selectedConfidencePreset?.isGemini == true ? "Gemini" : "Codex"
    }


    var selectedConfidenceDescription: String {
        if hybridConfidenceActive {
            return "Local judges \(selectedLocalConfidenceModels.joined(separator: " + ")); fallback \(providerDisplayName(selectedConfidenceFallbackReferee)) \(hybridGeminiFallbackModel), batch \(selectedConfidenceBatchSize), local gate 0.80"
        }
        if useHybridConfidence {
            return "Choose two local judges to enable local gate; direct fallback is \(providerDisplayName(selectedConfidenceFallbackReferee)) \(hybridGeminiFallbackModel)"
        }
        if selectedConfidencePreset?.isGemini == true {
            return "Checked by \(selectedConfidenceModel) via Gemini CLI, batch \(selectedConfidenceBatchSize), translation gate 0.75"
        }
        if selectedConfidencePreset?.isDeepSeek == true {
            return "Checked by \(selectedConfidenceModel) via DeepSeek paid API, batch \(selectedConfidenceBatchSize), translation gate 0.75"
        }
        return "Checked by \(selectedConfidenceModel), reasoning \(RusToPromptSettingsStore.defaultConfidenceReasoning), batch \(selectedConfidenceBatchSize), translation gate 0.75"
    }


    var queueStatusTone: SomaStatusTone {
        if queueManager.isPowerPaused || queueManager.isBatteryBlockingQueue { return .warning }
        if queueManager.isRunning { return .info }
        if queueManager.failedCount > 0 { return .warning }
        if queueManager.queuedCount > 0 { return .info }
        return .neutral
    }


    var queuePowerTone: SomaStatusTone {
        switch queueManager.powerSource {
        case .externalPower:
            return .good
        case .battery:
            return (queueManager.queuedCount > 0 || queueManager.isRunning) ? .warning : .neutral
        case .unknown:
            return .neutral
        }
    }

}

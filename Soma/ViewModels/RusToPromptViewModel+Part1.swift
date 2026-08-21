import Combine
import Foundation
extension RusToPromptViewModel {
    static let translatorPresets: [RusToPromptModelPreset] = [
        RusToPromptModelPreset(
            model: "deepseek-v4-pro", quality: "Best", speed: "Fast", ram: "Paid API",
            detail:
                "Recommended translator (bench winner): best quality (0.97), fastest (~2.8s), zero placeholder/empty defects, ~0 local RAM. Token cost is sub-cent at personal volume.",
            recommended: true, provider: "deepseek"),
        RusToPromptModelPreset(
            model: "deepseek-v4-flash", quality: "High", speed: "Fast", ram: "Paid API",
            detail: "Cheaper DeepSeek translator. Near-Pro quality (0.94) at lower token cost; good default for bulk.", recommended: false,
            provider: "deepseek"),
        RusToPromptModelPreset(
            model: "gpt-5.4-mini", quality: "Best", speed: "Medium", ram: "0 GB",
            detail: "Codex translator via subscription: strong cloud option, no local RAM use.", recommended: false, isCodex: true),
        RusToPromptModelPreset(
            model: "gpt-5.5", quality: "Best", speed: "Slow", ram: "0 GB",
            detail: "Codex translator via subscription: highest-quality cloud option when latency matters less than fidelity.",
            recommended: false, isCodex: true),
        RusToPromptModelPreset(
            model: "gemma4:e4b-mlx", quality: "High", speed: "Balanced", ram: "9.6 GB",
            detail: "Best local translator option (0.95, clean output). Use for offline / privacy; costs local RAM.", recommended: false),
        RusToPromptModelPreset(
            model: "qwen3.5:9b", quality: "Good", speed: "Balanced", ram: "6.6 GB",
            detail: "Lighter local fallback; mid quality (0.57 bench), occasional placeholder leaks.", recommended: false),
        RusToPromptModelPreset(
            model: "qwen3:8b", quality: "Good", speed: "Fast", ram: "5.2 GB", detail: "Fast local translation with lower memory pressure.",
            recommended: false),
    ]
    static let analyzerPresets: [RusToPromptModelPreset] = [
        RusToPromptModelPreset(
            model: "deepseek-v4-pro", quality: "Best", speed: "Fast", ram: "Paid API",
            detail: "Recommended improver: top prompt-polish quality at ~0 local RAM. Keeps the daily flow online and RAM-free.",
            recommended: true, provider: "deepseek"),
        RusToPromptModelPreset(
            model: "deepseek-v4-flash", quality: "High", speed: "Fast", ram: "Paid API",
            detail: "Cheaper DeepSeek improver. Lower token cost for prompt polishing.", recommended: false, provider: "deepseek"),
        RusToPromptModelPreset(
            model: "gpt-5.4-mini", quality: "Best", speed: "Medium", ram: "0 GB",
            detail: "Codex improver via subscription: strong prompt-polish quality, no local RAM use.", recommended: false, isCodex: true),
        RusToPromptModelPreset(
            model: "gpt-5.5", quality: "Best", speed: "Slow", ram: "0 GB",
            detail: "Codex improver via subscription: stricter and higher-quality prompt rewriting when latency is acceptable.",
            recommended: false, isCodex: true),
        RusToPromptModelPreset(
            model: "gemma4:e4b-mlx", quality: "High", speed: "Balanced", ram: "9.6 GB",
            detail: "Best local improver if you want it offline. Costs local RAM — prefer DeepSeek on a memory-tight machine.",
            recommended: false),
        RusToPromptModelPreset(
            model: "qwen3:14b", quality: "High", speed: "Medium", ram: "9.3 GB",
            detail: "Balanced local analyzer when you want a mid-size model.", recommended: false),
    ]
    static let confidencePresets: [RusToPromptModelPreset] = [
        RusToPromptModelPreset(
            model: "gpt-5.4-mini", quality: "Best", speed: "Medium", ram: "0 GB",
            detail:
                "Strict confidence judge via Codex CLI. Strong at detecting invented requirements, meta-prompts, and lost technical spans; use when you want a tougher review.",
            recommended: false),
        RusToPromptModelPreset(
            model: "gpt-5.5", quality: "Best", speed: "Slow", ram: "0 GB",
            detail: "Heavier Codex referee if available in your account; useful for stricter review.", recommended: false),
        RusToPromptModelPreset(
            model: "gpt-5-mini", quality: "High", speed: "Fast", ram: "0 GB",
            detail: "Faster Codex referee option if available in your account.", recommended: false),
        RusToPromptModelPreset(
            model: "o4-mini", quality: "Good", speed: "Fast", ram: "0 GB",
            detail: "Fast reasoning fallback for confidence checks if available in Codex CLI.", recommended: false),
        RusToPromptModelPreset(
            model: "deepseek-v4-flash", quality: "High", speed: "Fast", ram: "Paid API",
            detail: "DeepSeek paid API confidence judge. Lower-cost default DeepSeek option for quality checks.", recommended: false,
            provider: "deepseek"),
        RusToPromptModelPreset(
            model: "deepseek-v4-pro", quality: "Best", speed: "Medium", ram: "Paid API",
            detail: "DeepSeek paid API confidence judge. Use for stricter quality checks when token cost is acceptable.",
            recommended: false, provider: "deepseek"),
        RusToPromptModelPreset(
            model: "gemini-3-flash-preview", quality: "High", speed: "Medium", ram: "0 GB",
            detail:
                "Recommended Gemini referee from our test runs: good quality, better availability than Pro-class Gemini models, and useful when Gemini quota is otherwise unused.",
            recommended: false, provider: "gemini"),
        RusToPromptModelPreset(
            model: "gemini-3.1-flash-lite-preview", quality: "Good", speed: "Fast", ram: "0 GB",
            detail: "Recommended judge for daily use: fast, cheap/free-tier-friendly, 0 RAM, good quality (0.92 bench).", recommended: true,
            provider: "gemini"),
        RusToPromptModelPreset(
            model: "gemini-2.5-flash", quality: "Good", speed: "Medium", ram: "0 GB",
            detail: "Stable Gemini fallback if the Gemini 3 preview models are unavailable or rate-limited.", recommended: false,
            provider: "gemini"),
    ]
    var isBusy: Bool {
        phase == .translating || phase == .analyzing || phase == .checkingConfidence
    }
    var finalPromptForCopy: String {
        let improved = improvedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !improved.isEmpty { return improved }
        return translation.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func resetState() {
        inputPrompt = ""
        resetRunState()
    }
    func resetRunState() {
        phase = .idle
        translationResult = nil
        improveResult = nil
        confidenceResult = nil
        translation = ""
        improvedPrompt = ""
        errorMessage = nil
        warningMessage = nil
        confidenceWarning = nil
    }
    func transform(
        mode: RusToPromptMode = .fullPrompt, somaViewModel: SomaViewModel, ollama: OllamaManager,
        queueManager: RusToPromptQueueManager? = nil
    ) {
        let prompt = inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        resetRunState()
        phase = .translating
        Task { [weak self] in
            guard let self else { return }
            await runTransform(prompt: prompt, mode: mode, somaViewModel: somaViewModel, ollama: ollama, queueManager: queueManager)
        }
    }
    func runTransform(
        prompt: String, mode: RusToPromptMode = .fullPrompt, somaViewModel: SomaViewModel, ollama: OllamaManager,
        queueManager: RusToPromptQueueManager?
    ) async {
        do {
            let translated = try await somaViewModel.runRusToPromptTranslate(prompt: prompt, translatorModel: translatorModel)
            let translatedText = translated.translation ?? ""
            guard await applyTranslationResult(translated, translatedText: translatedText, ollama: ollama) else { return }
            if mode == .translateOnly {
                await MainActor.run {
                    phase = .done
                    ollama.checkStatus()
                }
                return
            }
            await MainActor.run { phase = .analyzing }
            let improved = try await somaViewModel.runRusToPromptImprove(prompt: translatedText, analyzerModel: analyzerModel)
            await applyImprovementResult(improved, sourcePrompt: prompt, ollama: ollama, queueManager: queueManager)
            await maybeCheckConfidence(prompt: prompt, translationText: translatedText, improved: improved, somaViewModel: somaViewModel)
        } catch {
            await MainActor.run {
                errorMessage = friendlyError(error.localizedDescription)
                phase = .failed
                ollama.checkStatus()
            }
        }
    }
    func applyTranslationResult(_ translated: RusToPromptTranslationResult, translatedText: String, ollama: OllamaManager) async -> Bool {
        await MainActor.run {
            translationResult = translated
            translation = translatedText
        }
        guard translated.status == "ok", !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await MainActor.run {
                errorMessage = translated.warningSummary
                phase = .failed
                ollama.checkStatus()
            }
            return false
        }
        return true
    }
    func applyImprovementResult(
        _ improved: RusToPromptImproveResult, sourcePrompt: String, ollama: OllamaManager, queueManager: RusToPromptQueueManager?
    ) async {
        await MainActor.run {
            improveResult = improved
            improvedPrompt = improved.promptForCopy
            warningMessage = improved.status == "degraded" ? improved.warningSummary : nil
            phase = improved.status == "degraded" ? .degraded : .done
            ollama.checkStatus()
            if !finalPromptForCopy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                queueManager?.enqueueRealPrompt(sourcePrompt, source: "Rus to Prompt")
            }
        }
    }
    func maybeCheckConfidence(prompt: String, translationText: String, improved: RusToPromptImproveResult, somaViewModel: SomaViewModel)
        async
    {
        guard confidenceEnabled, !finalPromptForCopy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await MainActor.run { phase = .checkingConfidence }
        do {
            let confidence = try await somaViewModel.runRusToPromptConfidence(
                prompt: prompt, translation: translationText, improvedPrompt: finalPromptForCopy, pipelineStatus: improved.status ?? "ok",
                warnings: improved.warnings ?? [], confidenceModel: confidenceModel,
                reasoningEffort: RusToPromptSettingsStore.defaultConfidenceReasoning)
            await MainActor.run {
                confidenceResult = confidence
                confidenceWarning = confidence.status == "failed" ? confidence.warningSummary : nil
                phase = improved.status == "degraded" ? .degraded : .done
            }
        } catch {
            await MainActor.run {
                confidenceWarning = "Confidence check failed: \(error.localizedDescription)"
                phase = improved.status == "degraded" ? .degraded : .done
            }
        }
    }
    func friendlyError(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("connection refused") || message.localizedCaseInsensitiveContains("offline") {
            return "Ollama is offline. Launch Local AI, then run Rus to Prompt again."
        }
        return message
    }
}

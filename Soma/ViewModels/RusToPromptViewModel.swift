import Combine
import Foundation

struct RusToPromptResult: Codable, Sendable, Hashable {
    let status: String?
    let source_language: String?
    let target_language: String?
    let translation_status: String?
    let translation_engine: String?
    let translation: String?
    let improved_prompt: String?
    let translator_model: String?
    let improver_model: String?
    let warnings: [String]?
    let protected_spans_count: Int?
    let translation_tokens: Int?
    let improved_prompt_tokens: Int?
    let original_prompt_hash: String?
}

struct RusToPromptTranslationResult: Codable, Sendable, Hashable {
    let status: String?
    let source_language: String?
    let target_language: String?
    let translation_status: String?
    let translation_engine: String?
    let translation: String?
    let translator_model: String?
    let warnings: [String]?
    let protected_spans_count: Int?
    let translation_tokens: Int?
    let original_prompt_hash: String?

    var warningSummary: String {
        let items = warnings?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        if !items.isEmpty { return items.joined(separator: "\n") }
        return "Translation did not return a usable English prompt."
    }
}

struct RusToPromptImproveResult: Codable, Sendable, Hashable {
    let status: String?
    let improved_prompt: String?
    let improver_model: String?
    let warnings: [String]?
    let protected_spans_count: Int?
    let improved_prompt_tokens: Int?

    var promptForCopy: String {
        improved_prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var warningSummary: String {
        let items = warnings?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        if !items.isEmpty { return items.joined(separator: "\n") }
        return "Analyzer returned a degraded prompt."
    }
}

struct RusToPromptConfidenceResult: Codable, Sendable, Hashable {
    let provider: String?
    let model: String?
    let reasoningEffort: String?
    let status: String?
    let confidence: Double?
    let verdict: String?
    let scores: [String: Int]?
    let warnings: [String]?
    let notes: [String]?
    let seconds: Double?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case model
        case reasoningEffort = "reasoning_effort"
        case status
        case confidence
        case verdict
        case scores
        case warnings
        case notes
        case seconds
        case error
    }

    var warningSummary: String {
        if let error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return error }
        let items = warnings?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        if !items.isEmpty { return items.joined(separator: "\n") }
        return "Confidence check did not return a score."
    }
}

enum RusToPromptPhase: String {
    case idle
    case translating
    case analyzing
    case checkingConfidence
    case done
    case degraded
    case failed
}

struct RusToPromptModelPreset: Identifiable, Hashable {
    let model: String
    let quality: String
    let speed: String
    let ram: String
    let detail: String
    let recommended: Bool
    var isCodex: Bool = false
    var provider: String? = nil

    var id: String { model }

    var isGemini: Bool {
        provider == "gemini" || model.lowercased().hasPrefix("gemini-") || model.lowercased().hasPrefix("auto-gemini")
    }
}

enum RusToPromptSettingsStore {
    static let translatorKey = "rusToPrompt.translatorModel"
    static let analyzerKey = "rusToPrompt.analyzerModel"
    static let confidenceKey = "rusToPrompt.confidenceModel"
    static let confidenceEnabledKey = "rusToPrompt.confidenceEnabled"
    static let defaultTranslator = "qwen3.5:9b"
    static let defaultAnalyzer = "qwen3-coder:30b-a3b-q4_K_M"
    static let defaultConfidence = "gpt-5.4-mini"
    nonisolated static let defaultConfidenceReasoning = "medium"

    static func translatorModel() -> String {
        UserDefaults.standard.string(forKey: translatorKey) ?? defaultTranslator
    }

    static func analyzerModel() -> String {
        UserDefaults.standard.string(forKey: analyzerKey) ?? defaultAnalyzer
    }

    static func confidenceModel() -> String {
        UserDefaults.standard.string(forKey: confidenceKey) ?? defaultConfidence
    }

    static func confidenceEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: confidenceEnabledKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: confidenceEnabledKey)
    }

    static func setTranslatorModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: translatorKey)
    }

    static func setAnalyzerModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: analyzerKey)
    }

    static func setConfidenceModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: confidenceKey)
    }

    static func setConfidenceEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: confidenceEnabledKey)
    }
}

@MainActor
final class RusToPromptViewModel: ObservableObject {
    @Published var inputPrompt = ""
    @Published var phase: RusToPromptPhase = .idle
    @Published var translationResult: RusToPromptTranslationResult?
    @Published var improveResult: RusToPromptImproveResult?
    @Published var confidenceResult: RusToPromptConfidenceResult?
    @Published var translation = ""
    @Published var improvedPrompt = ""
    @Published var errorMessage: String?
    @Published var warningMessage: String?
    @Published var confidenceWarning: String?
    @Published var translatorModel: String {
        didSet { RusToPromptSettingsStore.setTranslatorModel(translatorModel) }
    }
    @Published var analyzerModel: String {
        didSet { RusToPromptSettingsStore.setAnalyzerModel(analyzerModel) }
    }
    @Published var confidenceModel: String {
        didSet { RusToPromptSettingsStore.setConfidenceModel(confidenceModel) }
    }
    @Published var confidenceEnabled: Bool {
        didSet { RusToPromptSettingsStore.setConfidenceEnabled(confidenceEnabled) }
    }

    static let translatorPresets: [RusToPromptModelPreset] = [
        RusToPromptModelPreset(model: "qwen3.5:9b", quality: "High", speed: "Balanced", ram: "6.6 GB", detail: "Recommended translator: strong Russian-English quality with moderate memory use.", recommended: true),
        RusToPromptModelPreset(model: "gpt-5.4-mini", quality: "Best", speed: "Medium", ram: "0 GB", detail: "Codex translator via subscription: strongest cloud option for nuanced Russian-English translation, with no local RAM use.", recommended: false, isCodex: true),
        RusToPromptModelPreset(model: "gpt-5.5", quality: "Best", speed: "Slow", ram: "0 GB", detail: "Codex translator via subscription: highest-quality cloud option when latency matters less than fidelity.", recommended: false, isCodex: true),
        RusToPromptModelPreset(model: "qwen3:8b", quality: "Good", speed: "Fast", ram: "5.2 GB", detail: "Fast translation with good quality and lower memory pressure.", recommended: false),
        RusToPromptModelPreset(model: "qwen3:4b", quality: "Basic", speed: "Fastest", ram: "2.5 GB", detail: "Use when RAM matters more than translation nuance.", recommended: false),
        RusToPromptModelPreset(model: "gemma4:e4b", quality: "Good", speed: "Balanced", ram: "9.6 GB", detail: "Useful fallback if Qwen models are not available; higher memory for this role.", recommended: false),
    ]

    static let analyzerPresets: [RusToPromptModelPreset] = [
        RusToPromptModelPreset(model: "qwen3-coder:30b-a3b-q4_K_M", quality: "Best", speed: "Slow", ram: "18.6 GB", detail: "Recommended analyzer: highest prompt-polish quality, but heavy memory use.", recommended: true),
        RusToPromptModelPreset(model: "gpt-5.4-mini", quality: "Best", speed: "Medium", ram: "0 GB", detail: "Codex improver via subscription: strong prompt-polish quality, good instruction fidelity, and no local RAM use.", recommended: false, isCodex: true),
        RusToPromptModelPreset(model: "gpt-5.5", quality: "Best", speed: "Slow", ram: "0 GB", detail: "Codex improver via subscription: stricter and higher-quality prompt rewriting when latency is acceptable.", recommended: false, isCodex: true),
        RusToPromptModelPreset(model: "qwen3:30b-a3b", quality: "Best", speed: "Slow", ram: "18.6 GB", detail: "Strong general analyzer with similar memory cost to the coder model.", recommended: false),
        RusToPromptModelPreset(model: "qwen3:14b", quality: "High", speed: "Medium", ram: "9.3 GB", detail: "Balanced analyzer when the 30B models are too heavy.", recommended: false),
        RusToPromptModelPreset(model: "qwen3.5:9b", quality: "Good", speed: "Balanced", ram: "6.6 GB", detail: "Lower-memory analyzer with good general prompt quality.", recommended: false),
    ]

    static let confidencePresets: [RusToPromptModelPreset] = [
        RusToPromptModelPreset(model: "gpt-5.4-mini", quality: "Best", speed: "Medium", ram: "0 GB", detail: "Recommended confidence judge via Codex CLI. Strong at detecting invented requirements, meta-prompts, and lost technical spans.", recommended: true),
        RusToPromptModelPreset(model: "gpt-5.5", quality: "Best", speed: "Slow", ram: "0 GB", detail: "Heavier Codex referee if available in your account; useful for stricter review.", recommended: false),
        RusToPromptModelPreset(model: "gpt-5-mini", quality: "High", speed: "Fast", ram: "0 GB", detail: "Faster Codex referee option if available in your account.", recommended: false),
        RusToPromptModelPreset(model: "o4-mini", quality: "Good", speed: "Fast", ram: "0 GB", detail: "Fast reasoning fallback for confidence checks if available in Codex CLI.", recommended: false),
        RusToPromptModelPreset(model: "gemini-3-flash-preview", quality: "High", speed: "Medium", ram: "0 GB", detail: "Recommended Gemini referee from our test runs: good quality, better availability than Pro-class Gemini models, and useful when Gemini quota is otherwise unused.", recommended: false, provider: "gemini"),
        RusToPromptModelPreset(model: "gemini-3.1-flash-lite-preview", quality: "Good", speed: "Fast", ram: "0 GB", detail: "High-volume Gemini referee. Use for broad test sweeps when you want cheaper/faster checks and can tolerate a less strict judge.", recommended: false, provider: "gemini"),
        RusToPromptModelPreset(model: "gemini-2.5-flash", quality: "Good", speed: "Medium", ram: "0 GB", detail: "Stable Gemini fallback if the Gemini 3 preview models are unavailable or rate-limited.", recommended: false, provider: "gemini"),
    ]

    var isBusy: Bool {
        phase == .translating || phase == .analyzing || phase == .checkingConfidence
    }

    var finalPromptForCopy: String {
        let improved = improvedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !improved.isEmpty { return improved }
        return translation.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init() {
        translatorModel = RusToPromptSettingsStore.translatorModel()
        analyzerModel = RusToPromptSettingsStore.analyzerModel()
        confidenceModel = RusToPromptSettingsStore.confidenceModel()
        confidenceEnabled = RusToPromptSettingsStore.confidenceEnabled()
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

    func transform(somaViewModel: SomaViewModel, ollama: OllamaManager, queueManager: RusToPromptQueueManager? = nil) {
        let prompt = inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        resetRunState()
        phase = .translating
        let selectedTranslator = translatorModel
        let selectedAnalyzer = analyzerModel
        let selectedConfidenceModel = confidenceModel
        let shouldCheckConfidence = confidenceEnabled

        Task {
            do {
                let translated = try await somaViewModel.runRusToPromptTranslate(
                    prompt: prompt,
                    translatorModel: selectedTranslator
                )

                await MainActor.run {
                    translationResult = translated
                    translation = translated.translation ?? ""
                }

                guard translated.status == "ok", !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    await MainActor.run {
                        errorMessage = translated.warningSummary
                        phase = .failed
                        ollama.checkStatus()
                    }
                    return
                }

                await MainActor.run {
                    phase = .analyzing
                }

                let improved = try await somaViewModel.runRusToPromptImprove(
                    prompt: translation,
                    analyzerModel: selectedAnalyzer
                )

                await MainActor.run {
                    improveResult = improved
                    improvedPrompt = improved.promptForCopy
                    warningMessage = improved.status == "degraded" ? improved.warningSummary : nil
                    phase = improved.status == "degraded" ? .degraded : .done
                    ollama.checkStatus()
                    if !finalPromptForCopy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        queueManager?.enqueueRealPrompt(prompt, source: "Rus to Prompt")
                    }
                }

                guard shouldCheckConfidence, !finalPromptForCopy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }

                await MainActor.run {
                    phase = .checkingConfidence
                }

                do {
                    let confidence = try await somaViewModel.runRusToPromptConfidence(
                        prompt: prompt,
                        translation: translation,
                        improvedPrompt: finalPromptForCopy,
                        pipelineStatus: improved.status ?? "ok",
                        warnings: improved.warnings ?? [],
                        confidenceModel: selectedConfidenceModel,
                        reasoningEffort: RusToPromptSettingsStore.defaultConfidenceReasoning
                    )
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
            } catch {
                await MainActor.run {
                    let message = friendlyError(error.localizedDescription)
                    errorMessage = message
                    phase = .failed
                    ollama.checkStatus()
                }
            }
        }
    }

    private func friendlyError(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("connection refused") || message.localizedCaseInsensitiveContains("offline") {
            return "Ollama is offline. Launch Local AI, then run Rus to Prompt again."
        }
        return message
    }
}

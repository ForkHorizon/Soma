import Combine
import Foundation
nonisolated struct RusToPromptResult: Codable, Sendable, Hashable {
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
nonisolated struct RusToPromptTranslationResult: Codable, Sendable, Hashable {
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
nonisolated struct RusToPromptImproveResult: Codable, Sendable, Hashable {
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
nonisolated struct RusToPromptConfidenceResult: Codable, Sendable, Hashable {
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
/// What the Rus-to-Prompt run should produce. `translateOnly` stops after the English
/// translation (no prompt-improve, no confidence) — for when the user just wants a translation.
enum RusToPromptMode {
    case translateOnly
    case fullPrompt
}
nonisolated struct RusToPromptModelPreset: Identifiable, Hashable {
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
    var isDeepSeek: Bool {
        provider == "deepseek" || model.lowercased().hasPrefix("deepseek-")
    }
    var isOnlineProvider: Bool {
        isCodex || isGemini || isDeepSeek
    }
    var providerName: String {
        if isDeepSeek { return "DeepSeek" }
        if isGemini { return "Gemini" }
        if isCodex { return "Codex" }
        return "Local"
    }
}
nonisolated enum RusToPromptSettingsStore {
    static let translatorKey = "rusToPrompt.translatorModel"
    static let analyzerKey = "rusToPrompt.analyzerModel"
    static let confidenceKey = "rusToPrompt.confidenceModel"
    static let confidenceEnabledKey = "rusToPrompt.confidenceEnabled"
    // Defaults reflect the model-bench conclusion (June 2026): DeepSeek Pro is fast
    // and RAM-free; heavy local 30B stage models evict the working set on a 32 GB box.
    static let defaultTranslator = "deepseek-v4-pro"
    static let defaultAnalyzer = "deepseek-v4-pro"
    static let defaultConfidence = "gemini-3.1-flash-lite-preview"
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
    init() {
        translatorModel = RusToPromptSettingsStore.translatorModel()
        analyzerModel = RusToPromptSettingsStore.analyzerModel()
        confidenceModel = RusToPromptSettingsStore.confidenceModel()
        confidenceEnabled = RusToPromptSettingsStore.confidenceEnabled()
    }
}

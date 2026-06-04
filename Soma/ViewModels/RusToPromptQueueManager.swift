import Combine
import Foundation
enum RusToPromptQueueItemStatus: String, Codable, CaseIterable {
    case queued
    case waitingLocalAI = "waiting_local_ai"
    case running
    case completed
    case failed
    case blocked
    case interrupted
}
struct RusToPromptQueueSettings: Codable, Hashable {
    var autoEnqueueEnabled: Bool
    var translatorCandidates: [String]
    var improverCandidates: [String]
    var confidenceReferee: String
    var confidenceModel: String
    var localConfidenceModels: [String]
    var hybridGeminiModel: String
    var hybridFallbackReferee: String?
    var confidenceBatchSize: Int
    var cooldownSeconds: Double
    var ramWarningGB: Double
    static func defaults() -> RusToPromptQueueSettings {
        let translators = localModelsFromDefaults(
            key: "tests.rusToPrompt.translatorModels",
            fallback: [RusToPromptSettingsStore.defaultTranslator]
        )
        let improvers = localModelsFromDefaults(
            key: "tests.rusToPrompt.improverModels",
            fallback: [RusToPromptSettingsStore.defaultAnalyzer]
        )
        let localJudges = localModelsFromDefaults(
            key: "tests.rusToPrompt.localConfidenceModels",
            fallback: ["qwen3:30b-a3b", "qwen3-coder:30b-a3b-q4_K_M"]
        )
        let confidenceModel = UserDefaults.standard.string(forKey: "tests.rusToPrompt.confidenceModel") ?? "gemini-3-flash-preview"
        let batchSize = UserDefaults.standard.integer(forKey: "tests.rusToPrompt.confidenceBatchSize")
        return RusToPromptQueueSettings(
            autoEnqueueEnabled: false,
            translatorCandidates: translators,
            improverCandidates: improvers,
            confidenceReferee: localJudges.count >= 2 ? "hybrid" : "gemini",
            confidenceModel: confidenceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gemini-3-flash-preview" : confidenceModel,
            localConfidenceModels: Array(localJudges.prefix(2)),
            hybridGeminiModel: confidenceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gemini-3-flash-preview" : confidenceModel,
            hybridFallbackReferee: "gemini",
            confidenceBatchSize: [1, 5, 10, 20].contains(batchSize) ? batchSize : 10,
            cooldownSeconds: 30,
            ramWarningGB: 6
        )
    }
    static func localModelsFromDefaults(key: String, fallback: [String]) -> [String] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return fallback.filter { RusToPromptQueueManager.isLocalStageModel($0) }
        }
        let models = decoded
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && RusToPromptQueueManager.isLocalStageModel($0) }
        return models.isEmpty ? fallback.filter { RusToPromptQueueManager.isLocalStageModel($0) } : models
    }
}
struct RusToPromptQueueItemSnapshot: Codable, Hashable {
    var translatorModels: [String]
    var improverModels: [String]
    var confidenceReferee: String
    var confidenceModel: String
    var localConfidenceModels: [String]
    var hybridGeminiModel: String
    var hybridFallbackReferee: String?
    var confidenceBatchSize: Int
    var cooldownSeconds: Double
}
struct RusToPromptQueueItem: Identifiable, Codable, Hashable {
    var id: String
    var prompt: String
    var normalizedPrompt: String
    var source: String
    var status: RusToPromptQueueItemStatus
    var statusMessage: String
    var createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var outputPath: String?
    var runCount: Int
    var recoveredAfterRestart: Bool
    var snapshot: RusToPromptQueueItemSnapshot?
}
struct RusToPromptQueueDiskState: Codable {
    var settings: RusToPromptQueueSettings
    var items: [RusToPromptQueueItem]
    var isPaused: Bool?
    var isPowerPaused: Bool?
}
enum RusToPromptQueuePowerSource: String {
    case externalPower
    case battery
    case unknown
}
struct QueueProgressEvent: Decodable {
    let event: String?
    let stage: String?
    let caseID: String?
    let translatorModel: String?
    let analyzerModel: String?
    let operationIndex: Int?
    let totalOperations: Int?
    let batchSize: Int?
    let batchIndex: Int?
    let batchTotal: Int?
    let status: String?
    let reason: String?
    let confidence: Double?
    let confidenceModel: String?
    let confidenceJudgeIndex: Int?
    let confidenceJudgeTotal: Int?
    let confidenceItemIDs: [String]?
    let confidenceModelRefs: [QueueProgressModelRef]?
    enum CodingKeys: String, CodingKey {
        case event
        case stage
        case caseID = "case_id"
        case translatorModel = "translator_model"
        case analyzerModel = "analyzer_model"
        case operationIndex = "operation_index"
        case totalOperations = "total_operations"
        case batchSize = "batch_size"
        case batchIndex = "batch_index"
        case batchTotal = "batch_total"
        case status
        case reason
        case confidence
        case confidenceModel = "confidence_model"
        case confidenceJudgeIndex = "confidence_judge_index"
        case confidenceJudgeTotal = "confidence_judge_total"
        case confidenceItemIDs = "confidence_item_ids"
        case confidenceModelRefs = "confidence_model_refs"
    }
}
struct QueueProgressModelRef: Decodable, Hashable {
    let translatorModel: String?
    let analyzerModel: String?
    enum CodingKeys: String, CodingKey {
        case translatorModel = "translator_model"
        case analyzerModel = "analyzer_model"
    }
}
struct QueueModelProgressState: Hashable {
    let itemID: String
    let role: String
    let model: String
    var label: String
    var detail: String
    var status: String
    var updatedAt: Date
}
struct QueueOllamaTagsResponse: Decodable {
    let models: [OllamaInstalledModel]
}
@MainActor
final class RusToPromptQueueManager: ObservableObject {
    @Published var items: [RusToPromptQueueItem] = []
    @Published var settings: RusToPromptQueueSettings
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var currentStage = "Idle"
    @Published var currentModel = "-"
    @Published var currentOutputPath: String?
    @Published var recentActivity: [String] = []
    @Published var freeMemoryGB: Double?
    @Published var powerSource: RusToPromptQueuePowerSource = .unknown
    @Published var isPowerPaused = false
    @Published var modelProgress: [String: QueueModelProgressState] = [:]
    let progressPrefix = "SOMA_PROGRESS "
    let repoRootURL: URL
    let appSupportURL: URL
    let queueFileURL: URL
    var activeProcess: Process?
    var activeItemID: String?
    var activeControlFileURL: URL?
    var processOutputBuffer = ""
    var timer: Timer?
    var batteryStartOverrideItemID: String?
    init() {
        let sourceURL = URL(fileURLWithPath: #filePath)
        repoRootURL = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        appSupportURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Soma")
            .appendingPathComponent("RusToPromptQueue")
        queueFileURL = appSupportURL.appendingPathComponent("queue.json")
        settings = RusToPromptQueueSettings.defaults()
        powerSource = Self.readPowerSource()
        loadFromDisk()
        recoverRunningItems()
        applyPowerGate()
        saveToDisk()
        startTimer()
    }
    deinit {
        timer?.invalidate()
    }
}

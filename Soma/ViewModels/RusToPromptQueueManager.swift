import Combine
import Foundation
nonisolated enum RusToPromptQueueItemStatus: String, Codable, CaseIterable {
    case queued
    case waitingLocalAI = "waiting_local_ai"
    case running
    case completed
    case failed
    case blocked
    case interrupted
}
nonisolated struct RusToPromptQueueSettings: Codable, Hashable {
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
        let translators = stageModelsFromDefaults(
            key: "tests.rusToPrompt.translatorModels",
            fallback: [RusToPromptSettingsStore.defaultTranslator]
        )
        let improvers = stageModelsFromDefaults(
            key: "tests.rusToPrompt.improverModels",
            fallback: [RusToPromptSettingsStore.defaultAnalyzer]
        )
        // Fast, family-diverse local judges by default: the heavy 30B pair couldn't score the
        // improve stage within the timeout, so they dominated wall-clock. Hybrid escalates
        // uncertain items to the online referee anyway, so the local pass should be cheap.
        let localJudges = localModelsFromDefaults(
            key: "tests.rusToPrompt.localConfidenceModels",
            fallback: ["qwen3:8b", "qwen3.5:4b"]
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
            cooldownSeconds: 0,  // was 30: keep_alive now keeps models resident; the knob stays for thermal tuning
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
    static func stageModelsFromDefaults(key: String, fallback: [String]) -> [String] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return fallback.filter { RusToPromptQueueManager.isStageCandidateModel($0) }
        }
        let models = decoded
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && RusToPromptQueueManager.isStageCandidateModel($0) }
        return models.isEmpty ? fallback.filter { RusToPromptQueueManager.isStageCandidateModel($0) } : models
    }
}
nonisolated struct RusToPromptQueueItemSnapshot: Codable, Hashable {
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
nonisolated struct RusToPromptQueueItem: Identifiable, Codable, Hashable {
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
    var pid: Int32? = nil
}
nonisolated struct RusToPromptQueueDiskState: Codable {
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
nonisolated struct QueueProgressEvent: Decodable, Sendable {
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
nonisolated struct QueueProgressModelRef: Decodable, Hashable, Sendable {
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
nonisolated struct QueueOllamaTagsResponse: Decodable {
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
    var progressTickCount = 0           // 1s ticks; housekeeping runs every 5th
    var batteryStartOverrideItemID: String?
    // Re-attach support: the run is a detached child that survives app restarts.
    var activeReattachedPID: Int32?     // set only when re-attached to a still-running child (no Process handle)
    var reattachedExitInFlight = false  // finalization started; blocks double-entry during the async completion
    var progressLogURL: URL?            // progress.log being tailed for the active run
    var progressLogOffset: UInt64 = 0   // byte offset already consumed from progressLogURL
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

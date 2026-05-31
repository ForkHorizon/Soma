import AppKit
import Combine
import SwiftUI

private let testProgressEventPrefix = "SOMA_PROGRESS "

private enum TestOutputTab: String, CaseIterable, Identifiable {
    case progress = "Progress"
    case results = "Results"

    var id: String { rawValue }
}

private enum TestResultsMode: String, CaseIterable, Identifiable {
    case byModel = "By Model"
    case byCase = "By Case"

    var id: String { rawValue }
}

private enum TestBenchmarkMode: String, CaseIterable, Identifiable {
    case staged = "Staged"
    case translation = "Translation"
    case matrix = "Full Matrix"

    var id: String { rawValue }

    var cliValue: String {
        switch self {
        case .staged: return "staged"
        case .translation: return "translation"
        case .matrix: return "matrix"
        }
    }

    var shortDescription: String {
        switch self {
        case .staged:
            return "Rank translators per case, then send the best translation to each improver."
        case .translation:
            return "Only test Russian or mixed input -> English translation quality."
        case .matrix:
            return "Run every translator -> improver pair for end-to-end checks."
        }
    }
}

private enum TestModelRole {
    case translator
    case improver
}

private enum TestModelSort: String, CaseIterable, Identifiable {
    case smart = "Smart"
    case quality = "Quality"
    case speed = "Speed"
    case name = "Name"

    var id: String { rawValue }
}

private enum TestPipelineStep: Int, CaseIterable, Identifiable {
    case translate
    case translationCheck
    case improve
    case improveConfidence
    case overallConfidence
    case save

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .translate: return "Translate"
        case .translationCheck: return "Translation Check"
        case .improve: return "Improve"
        case .improveConfidence: return "Improve Confidence"
        case .overallConfidence: return "Overall Confidence"
        case .save: return "Save"
        }
    }

    var icon: String {
        switch self {
        case .translate: return "character.book.closed"
        case .translationCheck: return "checkmark.shield"
        case .improve: return "wand.and.sparkles"
        case .improveConfidence: return "gauge.with.dots.needle.50percent"
        case .overallConfidence: return "scope"
        case .save: return "tray.and.arrow.down"
        }
    }
}

private struct TestRankedModelPreset: Identifiable {
    let preset: RusToPromptModelPreset
    let stats: TestModelRoleStats?
    let quality: String
    let speed: String
    let detail: String

    var id: String { preset.id }
    var hasStats: Bool { stats != nil }
    var attempts: Int { stats?.attempts ?? 0 }
    var avgConfidence: Double? { stats?.avgConfidence }
    var avgSeconds: Double? { stats?.avgSeconds }
    var pipelineFailedCount: Int { stats?.pipelineFailedCount ?? 0 }
    var confidenceFailedCount: Int { stats?.confidenceFailedCount ?? 0 }
    var lowConfidenceCount: Int { stats?.lowConfidenceCount ?? 0 }
    var confidenceCount: Int { stats?.confidenceCount ?? 0 }
    var isBroken: Bool { quality == "Broken" }

    var pipelineFailRate: Double {
        attempts > 0 ? Double(pipelineFailedCount) / Double(attempts) : 0
    }

    var confidenceFailRate: Double {
        attempts > 0 ? Double(confidenceFailedCount) / Double(attempts) : 0
    }

    var qualityRank: Int {
        switch quality {
        case "Best": return 5
        case "High": return 4
        case "Good": return 3
        case "Risk": return 2
        case "No data": return 1
        case "Broken": return 0
        default: return 1
        }
    }
}

private struct TestProgressEvent: Decodable {
    let event: String
    let stage: String
    let timestamp: String?
    let caseID: String?
    let category: String?
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

    enum CodingKeys: String, CodingKey {
        case event
        case stage
        case timestamp
        case caseID = "case_id"
        case category
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
    }
}

private struct TestConfidenceAggregate: Decodable {
    let count: Int?
    let avg: Double?
    let median: Double?
    let min: Double?
    let failed: Int?
    let byStatus: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case count
        case avg
        case median
        case min
        case failed
        case byStatus = "by_status"
    }
}

private struct TestLowConfidenceCase: Decodable, Identifiable {
    let id: String
    let category: String?
    let status: String?
    let confidences: [String: Double]?
    let failedStages: [String]?
    let warnings: [String]?

    enum CodingKeys: String, CodingKey {
        case id
        case category
        case status
        case confidences
        case failedStages = "failed_stages"
        case warnings
    }
}

private struct TestRunConfidence: Decodable, Hashable {
    let status: String?
    let confidence: Double?
    let verdict: String?
    let error: String?
    let warnings: [String]?
    let reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case status
        case confidence
        case verdict
        case error
        case warnings
        case reasoningEffort = "reasoning_effort"
    }
}

private struct TestRunResult: Decodable, Identifiable, Hashable {
    let caseID: String
    let category: String?
    let status: String
    let translationStatus: String?
    let improveStatus: String?
    let seconds: Double
    let translation: String?
    let improvedPrompt: String?
    let translatorModel: String
    let analyzerModel: String
    let translationConfidence: TestRunConfidence?
    let improveConfidence: TestRunConfidence?
    let overallConfidence: TestRunConfidence?
    let warnings: [String]

    var id: String { "\(caseID)|\(translatorModel)|\(analyzerModel)" }
    var comboID: String { "\(translatorModel) -> \(analyzerModel)" }

    enum CodingKeys: String, CodingKey {
        case caseID = "id"
        case category
        case status
        case translationStatus = "translation_status"
        case improveStatus = "improve_status"
        case seconds
        case translation
        case improvedPrompt = "improved_prompt"
        case translatorModel = "translator_model"
        case analyzerModel = "analyzer_model"
        case translationConfidence = "translation_confidence"
        case improveConfidence = "improve_confidence"
        case overallConfidence = "overall_confidence"
        case warnings
    }
}

private struct TestPromptManifestCase: Decodable {
    let id: String
    let category: String?
    let prompt: String
}

private struct TestCaseRunGroup: Identifiable {
    let caseID: String
    let title: String
    let rows: [TestRunResult]

    var id: String { caseID }
}

private struct TestModelCombinationSummary: Decodable, Identifiable {
    let comboID: String
    let translatorModel: String
    let analyzerModel: String
    let total: Int
    let ok: Int
    let degraded: Int
    let failed: Int
    let translationConfidence: TestConfidenceAggregate
    let improveConfidence: TestConfidenceAggregate
    let overallConfidence: TestConfidenceAggregate
    let lowConfidenceCount: Int
    let durationSeconds: Double
    let topWarnings: [String]
    let lowCases: [TestLowConfidenceCase]

    var id: String { comboID }

    enum CodingKeys: String, CodingKey {
        case comboID = "combo_id"
        case translatorModel = "translator_model"
        case analyzerModel = "analyzer_model"
        case total
        case ok
        case degraded
        case failed
        case translationConfidence = "translation_confidence"
        case improveConfidence = "improve_confidence"
        case overallConfidence = "overall_confidence"
        case lowConfidenceCount = "low_confidence_count"
        case durationSeconds = "duration_seconds"
        case topWarnings = "top_warnings"
        case lowCases = "low_cases"
    }
}

private struct TestSummaryEnvelope: Decodable {
    let total: Int?
    let runStatus: String?
    let success: Bool?
    let confidenceFailedCount: Int?
    let externalErrorCounts: [String: Int]?
    let issueCounts: [String: Int]?
    let modelCombinations: [TestModelCombinationSummary]

    enum CodingKeys: String, CodingKey {
        case total
        case runStatus = "run_status"
        case success
        case confidenceFailedCount = "confidence_failed_count"
        case externalErrorCounts = "external_error_counts"
        case issueCounts = "issue_counts"
        case modelCombinations = "model_combinations"
    }
}

private struct TestModelStatsEnvelope: Decodable {
    let generatedAt: String?
    let scannedRuns: Int
    let skippedRuns: Int
    let translationModels: [TestModelRoleStats]
    let improverModels: [TestModelRoleStats]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case scannedRuns = "scanned_runs"
        case skippedRuns = "skipped_runs"
        case translationModels = "translation_models"
        case improverModels = "improver_models"
    }
}

private struct TestModelRoleStats: Decodable, Identifiable {
    let model: String
    let provider: String
    let attempts: Int
    let confidenceCount: Int
    let avgConfidence: Double?
    let medianConfidence: Double?
    let minConfidence: Double?
    let lowConfidenceCount: Int
    let confidenceFailedCount: Int
    let pipelineFailedCount: Int
    let degradedCount: Int
    let avgSeconds: Double?
    let lastTestedAt: String?
    let worstCases: [TestModelStatsCase]
    let topWarnings: [TestModelStatsWarning]
    let recentRuns: [TestModelStatsRecentRun]

    var id: String { "\(provider)|\(model)" }

    enum CodingKeys: String, CodingKey {
        case model
        case provider
        case attempts
        case confidenceCount = "confidence_count"
        case avgConfidence = "avg_confidence"
        case medianConfidence = "median_confidence"
        case minConfidence = "min_confidence"
        case lowConfidenceCount = "low_confidence_count"
        case confidenceFailedCount = "confidence_failed_count"
        case pipelineFailedCount = "pipeline_failed_count"
        case degradedCount = "degraded_count"
        case avgSeconds = "avg_seconds"
        case lastTestedAt = "last_tested_at"
        case worstCases = "worst_cases"
        case topWarnings = "top_warnings"
        case recentRuns = "recent_runs"
    }
}

private struct TestModelStatsCase: Decodable, Identifiable {
    let runDir: String
    let caseID: String
    let category: String?
    let confidence: Double?
    let confidenceFailed: Bool?
    let status: String?
    let relatedModel: String?
    let warnings: [String]?

    var id: String { "\(runDir)|\(caseID)|\(relatedModel ?? "")" }

    enum CodingKeys: String, CodingKey {
        case runDir = "run_dir"
        case caseID = "case_id"
        case category
        case confidence
        case confidenceFailed = "confidence_failed"
        case status
        case relatedModel = "related_model"
        case warnings
    }
}

private struct TestModelStatsWarning: Decodable, Identifiable {
    let warning: String
    let count: Int

    var id: String { warning }
}

private struct TestModelStatsRecentRun: Decodable, Identifiable {
    let runDir: String
    let finishedAt: String?
    let attempts: Int
    let avgConfidence: Double?
    let lowConfidenceCount: Int
    let failedCount: Int

    var id: String { runDir }

    enum CodingKeys: String, CodingKey {
        case runDir = "run_dir"
        case finishedAt = "finished_at"
        case attempts
        case avgConfidence = "avg_confidence"
        case lowConfidenceCount = "low_confidence_count"
        case failedCount = "failed_count"
    }
}

struct TestsView: View {
    @ObservedObject var ollama: OllamaManager
    @ObservedObject var queueManager: RusToPromptQueueManager
    @State private var caseCount = 0
    @State private var statusText = ""
    @State private var lastCasesModifiedAt: Date?
    @State private var selectedTranslatorModels: Set<String> = []
    @State private var selectedImproverModels: Set<String> = []
    @State private var selectedConfidenceModel = RusToPromptSettingsStore.defaultConfidence
    @State private var selectedLocalConfidenceModels: [String] = ["qwen3:30b-a3b", "qwen3-coder:30b-a3b-q4_K_M"]
    @State private var useHybridConfidence = true
    @State private var selectedConfidenceBatchSize = 10
    @State private var selectedBenchmarkMode: TestBenchmarkMode = .staged
    @State private var selectedCasesFileName = "rus_to_prompt_cases.txt"
    @State private var caseFiles: [URL] = []
    @State private var isRunningTests = false
    @State private var activeTestProcess: Process?
    @State private var currentRunIndex = 0
    @State private var totalRunCount = 0
    @State private var completedCases = 0
    @State private var totalCasesToRun = 0
    @State private var progressValue = 0.0
    @State private var currentCaseID = "Idle"
    @State private var currentStage = "Idle"
    @State private var currentStageStartedAt = Date()
    @State private var currentStageElapsedSeconds = 0.0
    @State private var currentTestStatus = "Not started"
    @State private var currentModelPair = "No active run"
    @State private var lastRunOutputURL: URL?
    @State private var progressLines: [String] = []
    @State private var rawProgressLines: [String] = []
    @State private var currentProgressEvent: TestProgressEvent?
    @State private var runStartedAt: Date?
    @State private var rejectedTranslationCount = 0
    @State private var skippedImproverCount = 0
    @State private var confidenceBatchesStarted = 0
    @State private var confidenceBatchesFinished = 0
    @State private var rejectedTranslationKeys: Set<String> = []
    @State private var translationGateState = "Pending"
    @State private var processOutputBuffer = ""
    @State private var selectedOutputTab: TestOutputTab = .progress
    @State private var selectedResultsMode: TestResultsMode = .byModel
    @State private var resultRows: [TestModelCombinationSummary] = []
    @State private var resultRunRows: [TestRunResult] = []
    @State private var resultPromptByCaseID: [String: String] = [:]
    @State private var selectedResultRowID: String?
    @State private var selectedRunRowID: String?
    @State private var resultsStatusText = "No results yet"
    @State private var showModelStats = false
    @State private var showQueue = false
    @State private var modelStats: TestModelStatsEnvelope?
    @State private var modelStatsStatusText = "Not loaded"
    @State private var isLoadingModelStats = false
    @State private var selectedTranslationStatsID: String?
    @State private var selectedImproverStatsID: String?
    @State private var showTranslatorModels = false
    @State private var showImproverModels = false
    @State private var showLocalConfidenceModels = false
    @State private var showQueueLocalConfidenceModels = false
    @State private var translatorModelSort: TestModelSort = .smart
    @State private var improverModelSort: TestModelSort = .smart
    @State private var customTranslatorModel = ""
    @State private var customImproverModel = ""
    private let refreshTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    private let translatorModelsKey = "tests.rusToPrompt.translatorModels"
    private let improverModelsKey = "tests.rusToPrompt.improverModels"
    private let confidenceModelKey = "tests.rusToPrompt.confidenceModel"
    private let localConfidenceModelsKey = "tests.rusToPrompt.localConfidenceModels"
    private let hybridConfidenceKey = "tests.rusToPrompt.hybridConfidence"
    private let confidenceBatchSizeKey = "tests.rusToPrompt.confidenceBatchSize"
    private let benchmarkModeKey = "tests.rusToPrompt.benchmarkMode"
    private let casesFileKey = "tests.rusToPrompt.casesFile"
    private let lastRunOutputKey = "tests.rusToPrompt.lastRunOutputPath"
    private let confidenceWorkers = 3

    private var testTranslatorPresets: [RusToPromptModelPreset] {
        mergePresets(RusToPromptViewModel.translatorPresets + onlineStagePresets)
    }

    private var testImproverPresets: [RusToPromptModelPreset] {
        mergePresets(RusToPromptViewModel.analyzerPresets + onlineStagePresets)
    }

    private var onlineStagePresets: [RusToPromptModelPreset] {
        [
            RusToPromptModelPreset(model: "gpt-5.5", quality: "Best", speed: "Slow", ram: "0 GB", detail: "Codex GPT-5.5 via subscription. Highest-quality online stage model; use medium reasoning for bulk tests and high only for small samples.", recommended: false, isCodex: true),
            RusToPromptModelPreset(model: "gpt-5.4", quality: "Best", speed: "Slow", ram: "0 GB", detail: "Codex GPT-5.4 via subscription. Strong online stage model to compare against GPT-5.5 and mini.", recommended: false, isCodex: true),
            RusToPromptModelPreset(model: "gpt-5.4-mini", quality: "High", speed: "Medium", ram: "0 GB", detail: "Codex GPT-5.4-Mini via subscription. Good bulk online baseline with lower latency and lower expected usage pressure than frontier models.", recommended: false, isCodex: true),
            RusToPromptModelPreset(model: "gpt-5.3-codex", quality: "High", speed: "Medium", ram: "0 GB", detail: "Codex-specialized model. Useful to test prompt-improvement and code-heavy wording against standard GPT models.", recommended: false, isCodex: true),
            RusToPromptModelPreset(model: "gpt-5.3-codex-spark", quality: "Good", speed: "Medium", ram: "0 GB", detail: "Codex Spark model. Useful as a cheaper/faster Codex-flavored candidate; default catalog reasoning is high, but Soma passes medium for test stages.", recommended: false, isCodex: true),
            RusToPromptModelPreset(model: "gpt-5.2", quality: "Good", speed: "Medium", ram: "0 GB", detail: "Older Codex-accessible GPT model. Keep it for regression comparison against newer GPT/Codex models.", recommended: false, isCodex: true),
            RusToPromptModelPreset(model: "codex-auto-review", quality: "Good", speed: "Medium", ram: "0 GB", detail: "Codex auto-review model from the local Codex catalog. Mostly useful as an experimental judge/improver comparison.", recommended: false, isCodex: true),
            RusToPromptModelPreset(model: "gemini-3-flash-preview", quality: "High", speed: "Medium", ram: "0 GB", detail: "Gemini CLI Flash candidate. Best first Gemini option for bulk translation/improvement tests while using your Google One AI Pro quota.", recommended: false, provider: "gemini"),
            RusToPromptModelPreset(model: "gemini-3-pro-preview", quality: "Best", speed: "Slow", ram: "0 GB", detail: "Gemini CLI Pro candidate. Use for smaller quality samples or hard cases before running a full sweep.", recommended: false, provider: "gemini"),
            RusToPromptModelPreset(model: "gemini-3.1-pro-preview", quality: "Best", speed: "Slow", ram: "0 GB", detail: "Gemini CLI Pro preview candidate. Strong quality option when speed and quota pressure are less important.", recommended: false, provider: "gemini"),
            RusToPromptModelPreset(model: "gemini-3.1-flash-lite-preview", quality: "Good", speed: "Fast", ram: "0 GB", detail: "Gemini CLI Flash Lite candidate. Use for high-volume sweeps when approximate ranking is enough.", recommended: false, provider: "gemini"),
            RusToPromptModelPreset(model: "gemini-2.5-pro", quality: "High", speed: "Slow", ram: "0 GB", detail: "Stable Gemini Pro fallback for quality checks if Gemini 3 preview models are unavailable.", recommended: false, provider: "gemini"),
            RusToPromptModelPreset(model: "gemini-2.5-flash", quality: "Good", speed: "Medium", ram: "0 GB", detail: "Stable Gemini Flash fallback for broad tests.", recommended: false, provider: "gemini"),
            RusToPromptModelPreset(model: "gemini-2.5-flash-lite", quality: "Good", speed: "Fast", ram: "0 GB", detail: "Stable Gemini Flash Lite fallback for high-volume runs.", recommended: false, provider: "gemini")
        ]
    }

    private var selectedConfidencePreset: RusToPromptModelPreset? {
        RusToPromptViewModel.confidencePresets.first { $0.model == selectedConfidenceModel }
    }

    private var hybridConfidenceActive: Bool {
        useHybridConfidence && selectedLocalConfidenceModels.count >= 2
    }

    private var effectiveConfidenceWorkers: Int {
        hybridConfidenceActive ? 1 : confidenceWorkers
    }

    private var hybridGeminiFallbackModel: String {
        selectedConfidenceModel
    }

    private var confidenceModelPresetsForMenu: [RusToPromptModelPreset] {
        RusToPromptViewModel.confidencePresets
    }

    private var selectedConfidenceFallbackReferee: String {
        selectedConfidencePreset?.isGemini == true ? "gemini" : "codex"
    }

    private var selectedConfidenceReferee: String {
        if hybridConfidenceActive { return "hybrid" }
        return selectedConfidencePreset?.isGemini == true ? "gemini" : "codex"
    }

    private var selectedConfidenceProviderLabel: String {
        if hybridConfidenceActive { return "Local + \(selectedConfidenceFallbackReferee.capitalized)" }
        return selectedConfidencePreset?.isGemini == true ? "Gemini" : "Codex"
    }

    private var selectedConfidenceDescription: String {
        if hybridConfidenceActive {
            return "Local judges \(selectedLocalConfidenceModels.joined(separator: " + ")); fallback \(selectedConfidenceFallbackReferee) \(hybridGeminiFallbackModel), batch \(selectedConfidenceBatchSize), local gate 0.80"
        }
        if useHybridConfidence {
            return "Choose two local judges to enable local gate; direct fallback is \(selectedConfidenceFallbackReferee) \(hybridGeminiFallbackModel)"
        }
        if selectedConfidencePreset?.isGemini == true {
            return "Checked by \(selectedConfidenceModel) via Gemini CLI, batch \(selectedConfidenceBatchSize), translation gate 0.75"
        }
        return "Checked by \(selectedConfidenceModel), reasoning \(RusToPromptSettingsStore.defaultConfidenceReasoning), batch \(selectedConfidenceBatchSize), translation gate 0.75"
    }

    private var queueStatusTone: SomaStatusTone {
        if queueManager.isRunning { return .info }
        if queueManager.failedCount > 0 { return .warning }
        if queueManager.queuedCount > 0 { return .info }
        return .neutral
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            HStack(alignment: .top, spacing: 12) {
                testCasesPanel
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                modelSelectionPanel(
                    title: "Models to test (Translator)",
                    icon: "character.bubble",
                    role: .translator,
                    knownPresets: testTranslatorPresets,
                    selection: $selectedTranslatorModels,
                    storageKey: translatorModelsKey,
                    isPresented: $showTranslatorModels,
                    sort: $translatorModelSort,
                    customModel: $customTranslatorModel
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
                modelSelectionPanel(
                    title: "Models to test (Improver)",
                    icon: "brain",
                    role: .improver,
                    knownPresets: testImproverPresets,
                    selection: $selectedImproverModels,
                    storageKey: improverModelsKey,
                    isPresented: $showImproverModels,
                    sort: $improverModelSort,
                    customModel: $customImproverModel
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 18)

            confidencePanel
                .padding(.horizontal, 18)

            benchmarkModePanel
                .padding(.horizontal, 18)
            .padding(.bottom, 18)

            testRunControls
                .padding(.horizontal, 18)

            testOutputTabs
                .padding(.horizontal, 18)
                .padding(.bottom, 18)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SomaDesign.pageBackground)
        .onAppear {
            migrateLegacyCaseFilesIfNeeded()
            refreshCaseFiles()
            loadSelectedCasesFile()
            loadCases()
            loadModelSelections()
            loadConfidenceModel()
            loadLocalConfidenceModels()
            loadHybridConfidence()
            loadConfidenceBatchSize()
            loadBenchmarkMode()
            loadLastResultsIfAvailable()
            loadModelStatsIfNeeded()
            ollama.refreshInstalledModels()
            ollama.checkStatus()
        }
        .onReceive(refreshTimer) { _ in
            refreshCasesIfChanged()
            if isRunningTests {
                currentStageElapsedSeconds = Date().timeIntervalSince(currentStageStartedAt)
            }
        }
        .onChange(of: queueManager.completedCount) { _, _ in
            loadModelStats()
        }
        .sheet(isPresented: $showModelStats) {
            modelStatsSheet
                .frame(minWidth: 1080, minHeight: 720)
                .onAppear {
                    loadModelStats()
                }
        }
        .sheet(isPresented: $showQueue) {
            queueSheet
                .frame(minWidth: 1120, minHeight: 740)
                .onAppear {
                    queueManager.refreshFreeMemory()
                    queueManager.startNextIfPossible()
                }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Tests", systemImage: "testtube.2")
                .font(.title3.weight(.semibold))
                .foregroundColor(.primary)

            Spacer()

            Button {
                showQueue = true
            } label: {
                Label("Queue", systemImage: "tray.full")
                StatusChip(text: queueManager.statusBadgeText, tone: queueStatusTone)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                showModelStats = true
            } label: {
                Label("Model Stats", systemImage: "chart.bar.xaxis")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                openStressLogsFolder()
            } label: {
                Label("Open Logs", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open the .stress logs folder in Finder")

            Button {
                loadCases()
                loadLastResultsIfAvailable()
                ollama.refreshInstalledModels()
                ollama.checkStatus()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                openCasesInVSCode()
            } label: {
                Label("Open in VSCode", systemImage: "curlybraces.square")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private var queueSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("Real Prompt Queue", systemImage: "tray.full")
                    .font(.title3.weight(.semibold))
                StatusChip(text: queueManager.statusBadgeText, tone: queueStatusTone)
                StatusChip(text: "\(queueManager.completedCount) done", tone: .good)
                if queueManager.failedCount > 0 {
                    StatusChip(text: "\(queueManager.failedCount) needs attention", tone: .warning)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: queueManager.queueDirectoryPath))
                } label: {
                    Label("Open Queue Folder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                Button {
                    openStressLogsFolder()
                } label: {
                    Label("Open Logs", systemImage: "folder.badge.gearshape")
                }
                .buttonStyle(.bordered)
            }

            HStack(alignment: .top, spacing: 12) {
                queueSettingsPanel
                    .frame(width: 360, alignment: .topLeading)
                queueItemsPanel
                queueActivePanel
                    .frame(width: 340, alignment: .topLeading)
            }
        }
        .padding(18)
        .background(SomaDesign.pageBackground)
    }

    private var queueSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.headline)

            Toggle("Auto benchmark real prompts", isOn: Binding(
                get: { queueManager.settings.autoEnqueueEnabled },
                set: { queueManager.setAutoEnqueueEnabled($0) }
            ))
            .toggleStyle(.switch)

            queueCandidatePanel(
                title: "Translators",
                selected: queueManager.settings.translatorCandidates,
                update: queueManager.updateTranslatorCandidates
            )

            queueCandidatePanel(
                title: "Improvers",
                selected: queueManager.settings.improverCandidates,
                update: queueManager.updateImproverCandidates
            )

            queueConfidencePanel

            Stepper(value: Binding(
                get: { Int(queueManager.settings.cooldownSeconds) },
                set: { queueManager.updateCooldown(seconds: Double($0)) }
            ), in: 0...600, step: 5) {
                Text("Cooldown \(Int(queueManager.settings.cooldownSeconds))s")
            }

            Stepper(value: Binding(
                get: { Int(queueManager.settings.ramWarningGB) },
                set: { queueManager.updateRAMWarning(gb: Double($0)) }
            ), in: 0...64, step: 1) {
                Text("RAM warning \(Int(queueManager.settings.ramWarningGB)) GB")
            }

            HStack {
                Text("Free RAM")
                    .foregroundColor(.secondary)
                Spacer()
                let free = queueManager.freeMemoryGB
                StatusChip(
                    text: free.map { String(format: "%.1f GB", $0) } ?? "Unknown",
                    tone: (free ?? 999) < queueManager.settings.ramWarningGB ? .warning : .good
                )
                Button {
                    queueManager.refreshFreeMemory()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    private var queueConfidencePanel: some View {
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

    private var queueConfidenceFallbackReferee: String {
        let stored = queueManager.settings.hybridFallbackReferee ?? ""
        if ["off", "gemini", "codex"].contains(stored) {
            return stored
        }
        if queueManager.settings.confidenceReferee == "gemini" || queueManager.settings.confidenceReferee == "codex" {
            return queueManager.settings.confidenceReferee
        }
        let model = queueManager.settings.confidenceModel
        return isGeminiModelName(model) ? "gemini" : (isCodexModelName(model) ? "codex" : "off")
    }

    private var queueConfidenceModeLabel: String {
        let localCount = queueManager.settings.localConfidenceModels.count
        let fallback = queueConfidenceFallbackReferee
        if localCount >= 2 {
            return fallback == "off" ? "Local x2" : "Local x2 + \(fallback.capitalized)"
        }
        if localCount == 1 && fallback == "off" {
            return "Local"
        }
        if fallback == "off" {
            return "Off"
        }
        return fallback.capitalized
    }

    private var queueConfidenceDescription: String {
        let locals = queueManager.settings.localConfidenceModels.prefix(2).joined(separator: " + ")
        let fallback = queueConfidenceFallbackReferee
        if queueManager.settings.localConfidenceModels.count >= 2 {
            let fallbackText = fallback == "off" ? "no online fallback" : "\(fallback) fallback \(queueManager.settings.confidenceModel)"
            return "Local gate: \(locals). If local judges fail, disagree, or score low: \(fallbackText)."
        }
        if queueManager.settings.localConfidenceModels.count == 1 && fallback == "off" {
            return "Local-only confidence with \(queueManager.settings.localConfidenceModels[0]). Add a second local judge for safer agreement checks."
        }
        if fallback == "off" {
            return "Confidence is disabled. Translation gates and quality stats will not be scored."
        }
        return "Online-only confidence with \(fallback) \(queueManager.settings.confidenceModel). Add two local judges to use a local gate before online fallback."
    }

    private var queueOnlineConfidencePresets: [RusToPromptModelPreset] {
        switch queueConfidenceFallbackReferee {
        case "gemini":
            return RusToPromptViewModel.confidencePresets.filter { $0.isGemini }
        case "codex":
            return RusToPromptViewModel.confidencePresets.filter { !$0.isGemini }
        default:
            return RusToPromptViewModel.confidencePresets
        }
    }

    private var queueLocalConfidenceModelsPopover: some View {
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

            Text("Pick two local Ollama models for the local gate. Online fallback is configured separately and can be Gemini, Codex, or Off.")
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

    private func queueLocalConfidenceModelRow(_ preset: RusToPromptModelPreset) -> some View {
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

    private func queueCandidatePanel(title: String, selected: [String], update: @escaping ([String]) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.bold())
                Spacer()
                StatusChip(text: "\(selected.count)", tone: selected.isEmpty ? .warning : .info)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(queueLocalModelRows(selected: selected), id: \.model) { preset in
                        let isSelected = selected.contains { $0.caseInsensitiveCompare(preset.model) == .orderedSame }
                        Toggle(isOn: Binding(
                            get: { isSelected },
                            set: { enabled in
                                var next = selected
                                if enabled {
                                    if !next.contains(where: { $0.caseInsensitiveCompare(preset.model) == .orderedSame }) {
                                        next.append(preset.model)
                                    }
                                } else {
                                    next.removeAll { $0.caseInsensitiveCompare(preset.model) == .orderedSame }
                                }
                                update(next)
                            }
                        )) {
                            HStack {
                                Text(preset.model)
                                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if !isInstalled(preset.model) {
                                    StatusChip(text: "Missing", tone: .warning)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .help(preset.detail)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
    }

    private var queueItemsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Queue")
                    .font(.headline)
                StatusChip(text: "\(queueManager.items.count) items", tone: queueManager.items.isEmpty ? .neutral : .info)
                Spacer()
                Button("Start") {
                    queueManager.startNextIfPossible()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(queueManager.isPaused ? "Resume" : "Pause") {
                    queueManager.isPaused ? queueManager.resume() : queueManager.pause()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Run Now") {
                    queueManager.runNow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Stop Current") {
                    queueManager.stopCurrent()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!queueManager.isRunning)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(queueManager.items) { item in
                        queueItemRow(item)
                    }
                }
            }
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    private var queueActivePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Active")
                .font(.headline)
            SomaKeyValueRow(label: "Stage", value: queueManager.currentStage, tone: queueManager.isRunning ? .info : .neutral)
            SomaKeyValueRow(label: "Model", value: queueManager.currentModel, tone: .neutral)
            if let output = queueManager.currentOutputPath {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: output))
                } label: {
                    Label("Open Output", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            Divider()
            Text("Recent activity")
                .font(.subheadline.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(queueManager.recentActivity, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    private func queueItemRow(_ item: RusToPromptQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                StatusChip(text: item.status.rawValue.replacingOccurrences(of: "_", with: " "), tone: queueItemTone(item.status))
                Text(item.id)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                Spacer()
                if let output = item.outputPath {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: output))
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help(output)
                }
                Button("Retry") {
                    queueManager.retry(item)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(item.status == .running)
                Button("Remove") {
                    queueManager.remove(item)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            Text(item.prompt)
                .font(.caption)
                .lineLimit(3)
                .textSelection(.enabled)
            if !item.statusMessage.isEmpty {
                Text(item.statusMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color(NSColor.textBackgroundColor).opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.10)))
    }

    private var testCasesPanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Input scenarios")
                        .font(.headline)
                    StatusChip(text: "\(caseCount) cases", tone: caseCount > 0 ? .info : .warning)
                }
                Text(casesURL.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Menu {
                    if caseFiles.isEmpty {
                        Text("No test files")
                    } else {
                        ForEach(caseFiles, id: \.path) { file in
                            Button {
                                selectCasesFile(file)
                            } label: {
                                HStack {
                                    if file.lastPathComponent == selectedCasesFileName {
                                        Image(systemName: "checkmark")
                                    }
                                    Text(file.lastPathComponent)
                                }
                            }
                        }
                    }
                } label: {
                    Label("File", systemImage: "doc.text")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)

                HStack(spacing: 6) {
                    Button {
                        createEmptyCasesFile()
                    } label: {
                        Label("New", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Create an empty test file")

                    Button {
                        deleteSelectedCasesFile()
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!FileManager.default.fileExists(atPath: casesURL.path))
                    .help("Remove the selected test file")
                }
            }
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    private func modelSelectionPanel(
        title: String,
        icon: String,
        role: TestModelRole,
        knownPresets: [RusToPromptModelPreset],
        selection: Binding<Set<String>>,
        storageKey: String,
        isPresented: Binding<Bool>,
        sort: Binding<TestModelSort>,
        customModel: Binding<String>
    ) -> some View {
        let rows = rankedModelPresets(role: role, knownPresets: knownPresets, sort: sort.wrappedValue, extraModels: selection.wrappedValue)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Text(selectedModelsSummary(selection.wrappedValue))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                StatusChip(text: "\(selection.wrappedValue.count) selected", tone: selection.wrappedValue.isEmpty ? .warning : .info)
            }

            Button {
                if !isPresented.wrappedValue {
                    loadModelStatsIfNeeded()
                }
                isPresented.wrappedValue.toggle()
            } label: {
                HStack {
                    Text("Choose models")
                    Spacer()
                    Image(systemName: isPresented.wrappedValue ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popover(isPresented: isPresented, arrowEdge: .bottom) {
                modelSelectionPopover(
                    title: title,
                    rows: rows,
                    selection: selection,
                    storageKey: storageKey,
                    sort: sort,
                    customModel: customModel
                )
            }
            .disabled(rows.isEmpty)
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    private func modelSelectionPopover(
        title: String,
        rows: [TestRankedModelPreset],
        selection: Binding<Set<String>>,
        storageKey: String,
        sort: Binding<TestModelSort>,
        customModel: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                StatusChip(text: "\(selection.wrappedValue.count) selected", tone: selection.wrappedValue.isEmpty ? .warning : .info)
                Spacer()
                if isLoadingModelStats {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    ollama.refreshInstalledModels()
                    loadModelStats()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            Picker("Sort", selection: sort) {
                ForEach(TestModelSort.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                TextField("Custom model, e.g. gemini-3-pro-preview or gpt-5.5", text: customModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                Button {
                    addCustomModel(customModel, selection: selection, storageKey: storageKey)
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(customModel.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .help("Add any model name supported by Ollama, Codex CLI, or Gemini CLI. Names starting with gpt-/o-/codex- run via Codex; gemini-/auto-gemini run via Gemini.")

            if rows.isEmpty {
                Text(ollama.isOllamaRunning ? "No installed Ollama models returned." : "Start Ollama to list installed models.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(rows) { row in
                            modelToggleRow(row, selection: selection, storageKey: storageKey)
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
        }
        .padding(12)
        .frame(width: 540)
    }

    private func modelToggleRow(
        _ row: TestRankedModelPreset,
        selection: Binding<Set<String>>,
        storageKey: String
    ) -> some View {
        let preset = row.preset
        return Toggle(isOn: Binding(
            get: { selection.wrappedValue.contains(preset.model) },
            set: { enabled in
                if enabled {
                    selection.wrappedValue.insert(preset.model)
                } else {
                    selection.wrappedValue.remove(preset.model)
                }
                saveModelSelection(selection.wrappedValue, key: storageKey)
            }
        )) {
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
                StatusChip(text: "Q \(row.quality)", tone: qualityTone(row.quality))
                StatusChip(text: "S \(row.speed)", tone: speedTone(row.speed))
                StatusChip(text: preset.ram, tone: .neutral)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color(NSColor.textBackgroundColor).opacity(0.64))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
        .help(row.detail)
    }

    private var confidencePanel: some View {
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
                    .help(size == 1 ? "Run every confidence check as its own request." : "Batch up to \(size) improver results that share one source prompt and translator.")
                }
            } label: {
                Label("Batch \(selectedConfidenceBatchSize)", systemImage: "square.stack.3d.up")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)

            Toggle("Local gate", isOn: Binding(
                get: { useHybridConfidence },
                set: { enabled in
                    useHybridConfidence = enabled
                    saveHybridConfidence(enabled)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Run two local Ollama confidence judges first. The selected online model is used only when local judges fail, disagree, or report low confidence.")

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

    private var localConfidenceModelsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Local confidence judges")
                    .font(.headline)
                StatusChip(text: "\(selectedLocalConfidenceModels.count)/2 selected", tone: selectedLocalConfidenceModels.count == 2 ? .good : .warning)
                Spacer()
                Button {
                    ollama.refreshInstalledModels()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            Text("The two local judges run first. The selected online fallback checks only cases with local failure, confidence below 0.80, or disagreement above 0.15.")
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

    private func localConfidenceModelRow(_ preset: RusToPromptModelPreset) -> some View {
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

    private var benchmarkModePanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.3.group.bubble")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Benchmark mode")
                        .font(.subheadline.bold())
                    StatusChip(text: selectedBenchmarkMode.rawValue, tone: .info)
                }
                Text(selectedBenchmarkMode.shortDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Picker("Benchmark mode", selection: Binding(
                    get: { selectedBenchmarkMode },
                    set: { mode in
                        selectedBenchmarkMode = mode
                        saveBenchmarkMode(mode)
                    }
                )) {
                    ForEach(TestBenchmarkMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)

                Text(benchmarkEstimateText)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    private var testRunControls: some View {
        HStack(spacing: 10) {
            Button {
                isRunningTests ? stopTests() : startAllTests()
            } label: {
                Label(isRunningTests ? "Stop Tests" : "Start All Tests", systemImage: isRunningTests ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!isRunningTests && !canStartTests)

            Text(runReadinessText)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if let lastRunOutputURL {
                Button {
                    NSWorkspace.shared.open(lastRunOutputURL)
                } label: {
                    Label("Open Output", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var testOutputTabs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Output", selection: $selectedOutputTab) {
                ForEach(TestOutputTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            switch selectedOutputTab {
            case .progress:
                testProgressPanel
            case .results:
                testResultsPanel
            }
        }
    }

    private var testProgressPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: isRunningTests ? "point.3.connected.trianglepath.dotted" : "chart.line.uptrend.xyaxis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Pipeline")
                            .font(.subheadline.bold())
                        StatusChip(text: currentStage, tone: pipelineStatusTone)
                    }
                    Text(currentTestStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(runElapsedText)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                    Text(totalCasesToRun > 0 ? "\(completedCases)/\(totalCasesToRun) operations" : "No active run")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(progressPercentText)
                        .font(.caption.monospacedDigit().bold())
                    Spacer()
                    Text("\(completedCases) complete, \(max(totalCasesToRun - completedCases, 0)) remaining")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ProgressView(value: progressValue, total: Double(max(totalCasesToRun, 1)))
                    .progressViewStyle(.linear)
            }

            pipelineTimeline

            HStack(alignment: .top, spacing: 12) {
                activeWorkPanel
                pipelineCountersPanel
            }

            recentActivityPanel
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    private var pipelineTimeline: some View {
        HStack(spacing: 8) {
            ForEach(TestPipelineStep.allCases.indices, id: \.self) { index in
                let step = TestPipelineStep.allCases[index]
                pipelineStepView(step)
                if index < TestPipelineStep.allCases.count - 1 {
                    Rectangle()
                        .fill(pipelineConnectorColor(before: step))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var activeWorkPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Active Work")
                    .font(.caption.bold())
                StatusChip(text: translationGateStateText, tone: translationGateTone)
                Spacer()
            }

            HStack(spacing: 12) {
                progressMetric("Case", currentCaseID)
                progressMetric("Translator", currentProgressEvent?.translatorModel ?? translatorFromPair)
                progressMetric("Improver / Batch", activeImproverOrBatchText)
                progressMetric("Confidence", activeConfidenceSummary)
            }

            if let reason = currentProgressEvent?.reason,
               !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.10)))
    }

    private var pipelineCountersPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Counters")
                .font(.caption.bold())

            HStack(spacing: 12) {
                progressMetric("Operation", totalCasesToRun > 0 ? "\(currentRunIndex)/\(totalCasesToRun)" : "-")
                progressMetric("Rejected", "\(rejectedTranslationCount)")
                progressMetric("Skipped", "\(skippedImproverCount)")
            }

            HStack(spacing: 12) {
                progressMetric("Confidence batches", "\(confidenceBatchesFinished)/\(confidenceBatchesStarted)")
                progressMetric("Running", "\(max(confidenceBatchesStarted - confidenceBatchesFinished, 0))")
                progressMetric("Queued", "\(max(estimatedConfidenceRequestCount - confidenceBatchesStarted, 0))")
                progressMetric("Est. requests", "~\(estimatedConfidenceRequestCount)")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.10)))
    }

    private var recentActivityPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Activity")
                    .font(.caption.bold())
                Spacer()
                if !rawProgressLines.isEmpty {
                    Text("\(rawProgressLines.count) raw lines")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            if progressLines.isEmpty {
                Text("Start tests to see live pipeline events.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(progressLines.suffix(6).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .textSelection(.enabled)
            }

            DisclosureGroup("Raw log") {
                Text(rawProgressLines.suffix(8).joined(separator: "\n"))
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(10)
        .background(Color(NSColor.textBackgroundColor).opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.10)))
    }

    private var testResultsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tablecells")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("Results")
                    .font(.subheadline.bold())
                StatusChip(text: "\(resultRunRows.count) operations", tone: resultRunRows.isEmpty ? .neutral : .info)
                StatusChip(text: "\(resultRows.count) combinations", tone: resultRows.isEmpty ? .neutral : .info)
                Spacer()
                Text(resultsStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if resultRows.isEmpty && resultRunRows.isEmpty {
                Text("Run tests to see operations and model-combination confidence.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                HStack {
                    Picker("Result mode", selection: $selectedResultsMode) {
                        ForEach(TestResultsMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)

                    Text(selectedResultsMode == .byModel
                         ? "Each row is one translator/improver pair aggregated across all cases."
                         : "Each row is one source prompt -> translation -> improved prompt operation.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                }

                switch selectedResultsMode {
                case .byModel:
                    modelResultsTable
                    if let selected = selectedResultRow {
                        resultDetailPanel(selected)
                    }
                case .byCase:
                    caseResultsTable
                    if let selected = selectedRunRow {
                        runDetailPanel(selected)
                    }
                }
            }
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    private var modelStatsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("Model Stats", systemImage: "chart.bar.xaxis")
                    .font(.title3.weight(.semibold))
                if let modelStats {
                    StatusChip(text: "\(modelStats.scannedRuns) runs", tone: modelStats.scannedRuns > 0 ? .info : .neutral)
                    StatusChip(text: "\(modelStats.skippedRuns) skipped", tone: modelStats.skippedRuns > 0 ? .warning : .neutral)
                }
                Spacer()
                if isLoadingModelStats {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    loadModelStats()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    openStressLogsFolder()
                } label: {
                    Label("Open Logs Folder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Close") {
                    showModelStats = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(modelStatsHeaderText)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            Divider()

            if let modelStats {
                if modelStats.translationModels.isEmpty && modelStats.improverModels.isEmpty {
                    Text("No model statistics yet. Run tests to populate .stress, then refresh this sheet.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            modelStatsSection(
                                title: "Translation Models",
                                subtitle: "Russian or mixed input -> English translation. Attempts are deduplicated across improvers.",
                                rows: modelStats.translationModels,
                                selectedID: $selectedTranslationStatsID
                            )
                            if let selected = selectedTranslationStats {
                                modelStatsDetailPanel(title: "Translation details", row: selected)
                            }

                            modelStatsSection(
                                title: "Improver Models",
                                subtitle: "English translation -> final polished prompt. Attempts are counted per actual improve operation.",
                                rows: modelStats.improverModels,
                                selectedID: $selectedImproverStatsID
                            )
                            if let selected = selectedImproverStats {
                                modelStatsDetailPanel(title: "Improver details", row: selected)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
            } else {
                Text(modelStatsStatusText)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(18)
        .background(SomaDesign.pageBackground)
    }

    private var modelStatsHeaderText: String {
        if let modelStats {
            let generated = shortDateTime(modelStats.generatedAt)
            return "\(modelStatsStatusText) · Generated \(generated) · Logs: \(stressDirectoryURL.path)"
        }
        return "\(modelStatsStatusText) · Logs: \(stressDirectoryURL.path)"
    }

    private var selectedTranslationStats: TestModelRoleStats? {
        guard let modelStats else { return nil }
        if let selectedTranslationStatsID,
           let selected = modelStats.translationModels.first(where: { $0.id == selectedTranslationStatsID }) {
            return selected
        }
        return modelStats.translationModels.first
    }

    private var selectedImproverStats: TestModelRoleStats? {
        guard let modelStats else { return nil }
        if let selectedImproverStatsID,
           let selected = modelStats.improverModels.first(where: { $0.id == selectedImproverStatsID }) {
            return selected
        }
        return modelStats.improverModels.first
    }

    private func modelStatsSection(
        title: String,
        subtitle: String,
        rows: [TestModelRoleStats],
        selectedID: Binding<String?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                StatusChip(text: "\(rows.count) models", tone: rows.isEmpty ? .neutral : .info)
                Spacer()
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if rows.isEmpty {
                Text("No rows yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.38))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 0) {
                    modelStatsHeaderRow
                    Divider()
                    ForEach(rows) { row in
                        modelStatsRow(row, selectedID: selectedID)
                        Divider()
                    }
                }
                .background(Color(NSColor.textBackgroundColor).opacity(0.40))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
            }
        }
    }

    private var modelStatsHeaderRow: some View {
        HStack(spacing: 10) {
            Text("Model").frame(maxWidth: .infinity, alignment: .leading)
            Text("Runs").frame(width: 58, alignment: .trailing)
            Text("Avg").frame(width: 50, alignment: .trailing)
            Text("Med").frame(width: 50, alignment: .trailing)
            Text("Min").frame(width: 50, alignment: .trailing)
            Text("Low").frame(width: 46, alignment: .trailing)
            Text("Conf fail").frame(width: 68, alignment: .trailing)
            Text("Pipe fail").frame(width: 68, alignment: .trailing)
            Text("Deg").frame(width: 42, alignment: .trailing)
            Text("Runtime").frame(width: 64, alignment: .trailing)
            Text("Last").frame(width: 136, alignment: .leading)
        }
        .font(.caption2.bold())
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func modelStatsRow(_ row: TestModelRoleStats, selectedID: Binding<String?>) -> some View {
        Button {
            selectedID.wrappedValue = row.id
        } label: {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text(row.model)
                        .font(.caption.monospaced().weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    StatusChip(text: row.provider, tone: providerTone(row.provider))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(row.attempts)").frame(width: 58, alignment: .trailing)
                Text(formatConfidence(row.avgConfidence)).foregroundColor(confidenceTone(row.avgConfidence).color).frame(width: 50, alignment: .trailing)
                Text(formatConfidence(row.medianConfidence)).frame(width: 50, alignment: .trailing)
                Text(formatConfidence(row.minConfidence)).foregroundColor(confidenceTone(row.minConfidence).color).frame(width: 50, alignment: .trailing)
                Text("\(row.lowConfidenceCount)").foregroundColor(row.lowConfidenceCount > 0 ? .orange : .secondary).frame(width: 46, alignment: .trailing)
                Text("\(row.confidenceFailedCount)").foregroundColor(row.confidenceFailedCount > 0 ? .orange : .secondary).frame(width: 68, alignment: .trailing)
                Text("\(row.pipelineFailedCount)").foregroundColor(row.pipelineFailedCount > 0 ? .red : .secondary).frame(width: 68, alignment: .trailing)
                Text("\(row.degradedCount)").foregroundColor(row.degradedCount > 0 ? .orange : .secondary).frame(width: 42, alignment: .trailing)
                Text(formatOptionalSeconds(row.avgSeconds)).frame(width: 64, alignment: .trailing)
                Text(shortDateTime(row.lastTestedAt)).frame(width: 136, alignment: .leading)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selectedID.wrappedValue == row.id ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
        .help("attempts \(row.attempts), confidence count \(row.confidenceCount)")
    }

    private func modelStatsDetailPanel(title: String, row: TestModelRoleStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(title): \(row.model)")
                    .font(.caption.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                StatusChip(text: row.provider, tone: providerTone(row.provider))
                Spacer()
                StatusChip(text: "\(row.attempts) attempts", tone: row.attempts > 0 ? .info : .neutral)
                StatusChip(text: "low \(row.lowConfidenceCount)", tone: row.lowConfidenceCount > 0 ? .warning : .good)
            }

            HStack(alignment: .top, spacing: 12) {
                modelStatsDetailColumn(
                    title: "Worst cases",
                    lines: row.worstCases.prefix(6).map { item in
                        let confidence = item.confidence.map { String(format: "%.2f", $0) } ?? (item.confidenceFailed == true ? "failed" : "n/a")
                        let related = item.relatedModel.map { " · \($0)" } ?? ""
                        return "\(item.caseID): \(confidence) · \(item.status ?? "unknown")\(related)"
                    }
                )
                modelStatsDetailColumn(
                    title: "Top warnings",
                    lines: row.topWarnings.prefix(6).map { "\($0.count)x \($0.warning)" }
                )
                modelStatsDetailColumn(
                    title: "Recent runs",
                    lines: row.recentRuns.prefix(6).map { run in
                        let name = URL(fileURLWithPath: run.runDir).lastPathComponent
                        return "\(shortDateTime(run.finishedAt)) · \(name) · \(run.attempts) · avg \(formatConfidence(run.avgConfidence))"
                    }
                )
            }
        }
        .padding(10)
        .background(Color(NSColor.textBackgroundColor).opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.10)))
    }

    private func modelStatsDetailColumn(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.bold())
            Text(lines.isEmpty ? "-" : lines.joined(separator: "\n"))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(8)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var modelResultsTable: some View {
        VStack(spacing: 0) {
            resultHeaderRow
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(resultRows) { row in
                        resultMatrixRow(row)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.40))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    private var caseResultsTable: some View {
        VStack(spacing: 0) {
            caseResultHeaderRow
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(resultCaseGroups, id: \.caseID) { group in
                        HStack {
                            Text(group.title)
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(group.rows.count) operations")
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.08))

                        ForEach(group.rows) { row in
                            caseRunRow(row)
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.40))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    private var caseResultHeaderRow: some View {
        HStack(spacing: 10) {
            Text("Pipeline").frame(maxWidth: .infinity, alignment: .leading)
            Text("Translation conf").frame(width: 96, alignment: .leading)
            Text("Improve conf").frame(width: 96, alignment: .leading)
            Text("Overall conf").frame(width: 96, alignment: .leading)
            Text("Status").frame(width: 76, alignment: .leading)
            Text("Low").frame(width: 44, alignment: .leading)
            Text("Time").frame(width: 58, alignment: .trailing)
        }
        .font(.caption2.bold())
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var resultHeaderRow: some View {
        HStack(spacing: 10) {
            Text("Model pair").frame(maxWidth: .infinity, alignment: .leading)
            Text("Translation conf").frame(width: 96, alignment: .leading)
            Text("Improve conf").frame(width: 96, alignment: .leading)
            Text("Overall conf").frame(width: 96, alignment: .leading)
            Text("OK/D/F").frame(width: 76, alignment: .leading)
            Text("Low").frame(width: 44, alignment: .leading)
            Text("Time").frame(width: 58, alignment: .trailing)
        }
        .font(.caption2.bold())
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func resultMatrixRow(_ row: TestModelCombinationSummary) -> some View {
        Button {
            selectedResultRowID = row.id
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Translator: \(row.translatorModel)")
                        .font(.caption.monospaced().weight(.semibold))
                        .lineLimit(1)
                    Text("Improver: \(row.analyzerModel)")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                confidenceSummaryCell(row.translationConfidence)
                    .frame(width: 96, alignment: .leading)
                confidenceSummaryCell(row.improveConfidence)
                    .frame(width: 96, alignment: .leading)
                confidenceSummaryCell(row.overallConfidence)
                    .frame(width: 96, alignment: .leading)
                Text("\(row.ok)/\(row.degraded)/\(row.failed)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(row.failed > 0 ? .red : (row.degraded > 0 ? .orange : .green))
                    .frame(width: 76, alignment: .leading)
                Text("\(row.lowConfidenceCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(row.lowConfidenceCount > 0 ? .orange : .secondary)
                    .frame(width: 44, alignment: .leading)
                Text(formatSeconds(row.durationSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selectedResultRowID == row.id ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func caseRunRow(_ row: TestRunResult) -> some View {
        Button {
            selectedRunRowID = row.id
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Translate: \(row.translatorModel)")
                        .font(.caption.monospaced().weight(.semibold))
                        .lineLimit(1)
                    Text("Improve: \(row.analyzerModel)")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                runConfidenceCell(row.translationConfidence)
                    .frame(width: 96, alignment: .leading)
                runConfidenceCell(row.improveConfidence)
                    .frame(width: 96, alignment: .leading)
                runConfidenceCell(row.overallConfidence)
                    .frame(width: 96, alignment: .leading)
                Text(row.status)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(runStatusTone(row.status).color)
                    .frame(width: 76, alignment: .leading)
                Text("\(runLowStageCount(row))")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(runLowStageCount(row) > 0 ? .orange : .secondary)
                    .frame(width: 44, alignment: .leading)
                Text(formatSeconds(row.seconds))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selectedRunRowID == row.id ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func confidenceSummaryCell(_ stats: TestConfidenceAggregate) -> some View {
        HStack(spacing: 4) {
            Text(formatConfidence(stats.avg))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundColor(confidenceTone(stats.avg, failed: stats.failed ?? 0).color)
            if (stats.failed ?? 0) > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.orange)
            }
        }
        .help("avg \(formatConfidence(stats.avg)), min \(formatConfidence(stats.min)), failed \(stats.failed ?? 0)")
    }

    private func runConfidenceCell(_ confidence: TestRunConfidence?) -> some View {
        let failed = confidence?.status == "failed"
        let value = failed ? nil : confidence?.confidence
        return HStack(spacing: 4) {
            Text(failed ? "failed" : formatConfidence(value))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundColor(confidenceTone(value, failed: failed ? 1 : 0).color)
            if failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.orange)
            }
        }
        .help(runConfidenceHelp(confidence))
    }

    private func resultDetailPanel(_ row: TestModelCombinationSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.comboID)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                StatusChip(text: "low \(row.lowConfidenceCount)", tone: row.lowConfidenceCount > 0 ? .warning : .good)
            }

            if !row.lowCases.isEmpty {
                Text(row.lowCases.prefix(5).map { lowCase in
                    let confidenceText = (lowCase.confidences ?? [:])
                        .map { "\($0.key) \(String(format: "%.2f", $0.value))" }
                        .sorted()
                        .joined(separator: ", ")
                    let failedText = (lowCase.failedStages ?? [])
                        .map { "\($0) failed" }
                        .sorted()
                        .joined(separator: ", ")
                    let details = [confidenceText, failedText]
                        .filter { !$0.isEmpty }
                        .joined(separator: ", ")
                    return "\(lowCase.id): \(details.isEmpty ? "low confidence" : details)"
                }.joined(separator: "\n"))
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .lineLimit(5)
                .textSelection(.enabled)
            }

            if !row.topWarnings.isEmpty {
                Text(row.topWarnings.prefix(3).joined(separator: "\n"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color(NSColor.textBackgroundColor).opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.10)))
    }

    private func runDetailPanel(_ row: TestRunResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(row.caseID) · Source -> Translation -> Improved Prompt")
                    .font(.caption.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                StatusChip(text: row.status, tone: runStatusTone(row.status))
                StatusChip(text: "low \(runLowStageCount(row))", tone: runLowStageCount(row) > 0 ? .warning : .good)
            }

            Text([
                "Translator model: \(row.translatorModel)",
                "Improver model: \(row.analyzerModel)",
                "Runtime: \(formatSeconds(row.seconds))"
            ].joined(separator: " · "))
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)

            Divider()

            HStack(alignment: .top, spacing: 12) {
                runTextStage(
                    title: "1. Source",
                    subtitle: row.category ?? row.caseID,
                    text: resultPromptByCaseID[row.caseID] ?? "Source prompt not found in prompts.json."
                )
                runTextStage(
                    title: "2. Translation",
                    subtitle: "\(row.translatorModel) · \(row.translationStatus ?? "translated") · conf \(runConfidenceSummary(row.translationConfidence))",
                    text: row.translation ?? ""
                )
                runTextStage(
                    title: "3. Improved",
                    subtitle: "\(row.analyzerModel) · \(row.improveStatus ?? row.status) · conf \(runConfidenceSummary(row.improveConfidence)) · overall \(runConfidenceSummary(row.overallConfidence))",
                    text: row.improvedPrompt ?? ""
                )
            }

            let warnings = row.warnings.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !warnings.isEmpty {
                Divider()
                Text(warnings.prefix(3).map { "- \($0)" }.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color(NSColor.textBackgroundColor).opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.10)))
    }

    private func runTextStage(title: String, subtitle: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            ScrollView {
                Text(text.isEmpty ? "-" : text)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 88, maxHeight: 150)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func progressMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pipelineStepView(_ step: TestPipelineStep) -> some View {
        let activeStep = activePipelineStep
        let isActive = step == activeStep && isRunningTests
        let isCompleted = step.rawValue < activeStep.rawValue || (!isRunningTests && currentStage == "Done")
        let tone = isActive ? pipelineStatusTone : (isCompleted ? SomaStatusTone.good : .neutral)

        return VStack(spacing: 4) {
            Image(systemName: isCompleted ? "checkmark.circle.fill" : step.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(tone.color)
                .frame(width: 24, height: 24)
                .background(tone.color.opacity(isActive ? 0.18 : 0.10))
                .clipShape(Circle())
            Text(step.title)
                .font(.caption2)
                .foregroundColor(isActive ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(width: 86)
        .help(step.title)
    }

    private func pipelineConnectorColor(before step: TestPipelineStep) -> Color {
        let activeStep = activePipelineStep
        if activeStep.rawValue > step.rawValue || (!isRunningTests && currentStage == "Done") {
            return SomaStatusTone.good.color.opacity(0.65)
        }
        if activeStep == step && isRunningTests {
            return Color.accentColor.opacity(0.45)
        }
        return Color.secondary.opacity(0.18)
    }

    private var activePipelineStep: TestPipelineStep {
        pipelineStep(for: currentProgressEvent?.stage ?? currentStage)
    }

    private func pipelineStep(for stage: String) -> TestPipelineStep {
        let normalized = stage.lowercased().replacingOccurrences(of: " ", with: "_")
        if normalized.contains("writing_result") || normalized == "done" {
            return .save
        }
        if normalized.contains("overall_confidence") {
            return .overallConfidence
        }
        if normalized.contains("improve_confidence") {
            return .improveConfidence
        }
        if normalized.contains("analyzing") {
            return .improve
        }
        if normalized.contains("translation_confidence") || normalized.contains("translation_rejected") {
            return .translationCheck
        }
        return .translate
    }

    private var pipelineStatusTone: SomaStatusTone {
        let normalizedStage = currentStage.lowercased()
        let normalizedStatus = currentProgressEvent?.status?.lowercased() ?? ""
        if normalizedStage.contains("fail") || normalizedStatus == "failed" { return .danger }
        if normalizedStage.contains("reject") || normalizedStatus == "rejected" { return .warning }
        if normalizedStage == "done" || normalizedStatus == "ok" || normalizedStatus == "accepted" { return .good }
        if isRunningTests { return .info }
        return .neutral
    }

    private var progressPercentText: String {
        guard totalCasesToRun > 0 else { return "0%" }
        let percent = min(max(progressValue / Double(max(totalCasesToRun, 1)), 0), 1) * 100
        return String(format: "%.0f%%", percent)
    }

    private var runElapsedText: String {
        guard let runStartedAt else { return "elapsed -" }
        return "elapsed \(formatSeconds(Date().timeIntervalSince(runStartedAt)))"
    }

    private var translationGateStateText: String {
        let stage = currentProgressEvent?.stage.lowercased() ?? ""
        let status = currentProgressEvent?.status?.lowercased() ?? ""
        if stage.contains("translation_rejected") || status == "rejected" {
            return "Gate rejected"
        }
        if stage.contains("translation_confidence") && status == "accepted" {
            return "Gate accepted"
        }
        if stage.contains("translation_confidence") || stage.contains("translation_confidence_batch") {
            return "Checking translation"
        }
        switch translationGateState {
        case "Accepted":
            return "Gate accepted"
        case "Rejected":
            return "Gate rejected"
        case "Checking":
            return "Checking translation"
        default:
            return "Gate pending"
        }
    }

    private var translationGateTone: SomaStatusTone {
        switch translationGateStateText {
        case "Gate accepted":
            return .good
        case "Gate rejected":
            return .warning
        case "Checking translation":
            return .info
        default:
            return .neutral
        }
    }

    private var activeImproverOrBatchText: String {
        guard let event = currentProgressEvent else {
            return analyzerFromPair
        }
        if event.stage.contains("confidence_batch") {
            let batch = {
                if let index = event.batchIndex, let total = event.batchTotal {
                    return "batch \(index)/\(total)"
                }
                return "batch"
            }()
            let size = event.batchSize.map { "\($0) item(s)" } ?? "items"
            if let analyzer = event.analyzerModel, !analyzer.isEmpty {
                return "\(analyzer) · \(batch), \(size)"
            }
            return "\(batch), \(size)"
        }
        if let analyzer = event.analyzerModel, !analyzer.isEmpty {
            return analyzer
        }
        return analyzerFromPair
    }

    private var translatorFromPair: String {
        currentModelPair.components(separatedBy: " -> ").first ?? currentModelPair
    }

    private var analyzerFromPair: String {
        let parts = currentModelPair.components(separatedBy: " -> ")
        guard parts.count > 1 else { return "-" }
        return parts[1]
    }

    private var casesDirectoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Scripts")
            .appendingPathComponent("rus_to_prompt_tests")
    }

    private var casesURL: URL {
        casesDirectoryURL.appendingPathComponent(selectedCasesFileName)
    }

    private var repoRootURL: URL {
        casesDirectoryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var stressScriptURL: URL {
        repoRootURL
            .appendingPathComponent("Scripts")
            .appendingPathComponent("rus_to_prompt_stress.py")
    }

    private var modelStatsScriptURL: URL {
        repoRootURL
            .appendingPathComponent("Scripts")
            .appendingPathComponent("rus_to_prompt_stats.py")
    }

    private var stressDirectoryURL: URL {
        repoRootURL.appendingPathComponent(".stress")
    }

    private var selectedResultRow: TestModelCombinationSummary? {
        guard let selectedResultRowID else { return resultRows.first }
        return resultRows.first(where: { $0.id == selectedResultRowID }) ?? resultRows.first
    }

    private var selectedRunRow: TestRunResult? {
        guard let selectedRunRowID else { return resultRunRows.first }
        return resultRunRows.first(where: { $0.id == selectedRunRowID }) ?? resultRunRows.first
    }

    private var resultCaseGroups: [TestCaseRunGroup] {
        let grouped = Dictionary(grouping: resultRunRows, by: \.caseID)
        return grouped.keys.sorted().map { caseID in
            let rows = grouped[caseID] ?? []
            let category = rows.first?.category?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = category?.isEmpty == false ? "\(caseID) · \(category ?? "")" : caseID
            return TestCaseRunGroup(
                caseID: caseID,
                title: title,
                rows: rows.sorted {
                    let lhs = effectiveConfidence($0.overallConfidence)
                    let rhs = effectiveConfidence($1.overallConfidence)
                    if lhs == rhs { return $0.comboID < $1.comboID }
                    return lhs > rhs
                }
            )
        }
    }

    private var canStartTests: Bool {
        caseCount > 0
            && FileManager.default.fileExists(atPath: casesURL.path)
            && FileManager.default.fileExists(atPath: stressScriptURL.path)
            && !selectedTranslatorModels.isEmpty
            && (selectedBenchmarkMode == .translation || !selectedImproverModels.isEmpty)
    }

    private var transformOperationCount: Int {
        switch selectedBenchmarkMode {
        case .translation:
            return caseCount * selectedTranslatorModels.count
        case .staged:
            return caseCount * (selectedTranslatorModels.count + selectedImproverModels.count)
        case .matrix:
            return caseCount * selectedTranslatorModels.count * selectedImproverModels.count
        }
    }

    private var logicalConfidenceCheckCount: Int {
        switch selectedBenchmarkMode {
        case .translation:
            return caseCount * selectedTranslatorModels.count
        case .staged:
            return (caseCount * selectedTranslatorModels.count) + (caseCount * selectedImproverModels.count * 2)
        case .matrix:
            let translationChecks = caseCount * selectedTranslatorModels.count
            return translationChecks + (transformOperationCount * 2)
        }
    }

    private var estimatedConfidenceRequestCount: Int {
        guard caseCount > 0, !selectedTranslatorModels.isEmpty else { return 0 }
        if selectedBenchmarkMode == .translation {
            return caseCount * selectedTranslatorModels.count
        }
        guard !selectedImproverModels.isEmpty else { return 0 }
        let translationGroups = caseCount * selectedTranslatorModels.count
        let batchesPerStage = (selectedImproverModels.count + selectedConfidenceBatchSize - 1) / selectedConfidenceBatchSize
        switch selectedBenchmarkMode {
        case .translation:
            return translationGroups
        case .staged:
            return translationGroups + (caseCount * 2 * max(batchesPerStage, 1))
        case .matrix:
            return translationGroups * (1 + 2 * max(batchesPerStage, 1))
        }
    }

    private var benchmarkEstimateText: String {
        switch selectedBenchmarkMode {
        case .translation:
            return "\(transformOperationCount) translation operations, \(logicalConfidenceCheckCount) confidence checks"
        case .staged:
            return "\(transformOperationCount) operations: \(caseCount * selectedTranslatorModels.count) translations + \(caseCount * selectedImproverModels.count) improver runs"
        case .matrix:
            return "\(transformOperationCount) full matrix operations"
        }
    }

    private var runReadinessText: String {
        if isRunningTests { return "Running \(totalCasesToRun) transform operations; confidence workers x\(effectiveConfidenceWorkers)." }
        if caseCount <= 0 { return "Add at least one test case to start." }
        if selectedTranslatorModels.isEmpty { return "Choose at least one translator model." }
        if selectedBenchmarkMode != .translation && selectedImproverModels.isEmpty { return "Choose at least one improver model." }
        if hybridConfidenceActive {
            return "\(selectedBenchmarkMode.rawValue): \(transformOperationCount) operations, \(logicalConfidenceCheckCount) confidence items, two local judges first; \(selectedConfidenceFallbackReferee.capitalized) only on issues."
        }
        return "\(selectedBenchmarkMode.rawValue): \(transformOperationCount) operations, \(logicalConfidenceCheckCount) checks as ~\(estimatedConfidenceRequestCount) batched requests x\(effectiveConfidenceWorkers)."
    }

    private var activeConfidenceSummary: String {
        if hybridConfidenceActive {
            return "Local x2 -> \(selectedConfidenceFallbackReferee) \(hybridGeminiFallbackModel)"
        }
        return "\(selectedConfidenceModel) · \(selectedConfidenceProviderLabel)"
    }

    private func formatConfidence(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.2f", value)
    }

    private func formatSeconds(_ value: Double) -> String {
        if value >= 60 {
            return String(format: "%.1fm", value / 60)
        }
        return String(format: "%.1fs", value)
    }

    private func formatOptionalSeconds(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return formatSeconds(value)
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private func shortDateTime(_ value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "-"
        }
        return String(value.prefix(19)).replacingOccurrences(of: "T", with: " ")
    }

    private func confidenceTone(_ value: Double?, failed: Int = 0) -> SomaStatusTone {
        if failed > 0 { return .warning }
        guard let value else { return .neutral }
        if value >= 0.85 { return .good }
        if value >= 0.75 { return .info }
        if value >= 0.50 { return .warning }
        return .danger
    }

    private func providerTone(_ provider: String) -> SomaStatusTone {
        switch provider {
        case "Codex":
            return .info
        case "Gemini":
            return .warning
        case "Local":
            return .good
        default:
            return .neutral
        }
    }

    private func runStatusTone(_ status: String) -> SomaStatusTone {
        switch status {
        case "ok", "translation_ready":
            return .good
        case "degraded":
            return .warning
        default:
            return .danger
        }
    }

    private func effectiveConfidence(_ confidence: TestRunConfidence?) -> Double {
        guard confidence?.status != "failed", let value = confidence?.confidence else { return -1 }
        return value
    }

    private func runLowStageCount(_ row: TestRunResult) -> Int {
        [row.translationConfidence, row.improveConfidence, row.overallConfidence].reduce(0) { count, confidence in
            if confidence?.status == "failed" { return count + 1 }
            if let value = confidence?.confidence, value < 0.75 { return count + 1 }
            return count
        }
    }

    private func runConfidenceHelp(_ confidence: TestRunConfidence?) -> String {
        guard let confidence else { return "No confidence result" }
        let value = confidence.confidence.map { String(format: "%.2f", $0) } ?? "n/a"
        let status = confidence.status ?? "unknown"
        let reasoning = confidence.reasoningEffort ?? RusToPromptSettingsStore.defaultConfidenceReasoning
        return "status \(status), confidence \(value), reasoning \(reasoning)"
    }

    private func runConfidenceSummary(_ confidence: TestRunConfidence?) -> String {
        guard let confidence else { return "n/a" }
        if confidence.status == "failed" { return "failed" }
        return "\(formatConfidence(confidence.confidence)) \(confidence.status ?? "unknown")"
    }

    private func loadCases() {
        do {
            let text = try String(contentsOf: casesURL, encoding: .utf8)
            caseCount = countCases(in: text)
            lastCasesModifiedAt = casesModifiedAt()
            statusText = "Loaded \(caseCount) cases"
        } catch {
            caseCount = 0
            lastCasesModifiedAt = nil
            statusText = "Could not load \(casesURL.path): \(error.localizedDescription)"
        }
    }

    private func refreshCasesIfChanged() {
        let previousFiles = caseFiles.map(\.lastPathComponent)
        refreshCaseFiles()
        if caseFiles.map(\.lastPathComponent) != previousFiles {
            loadSelectedCasesFile()
        }
        let modifiedAt = casesModifiedAt()
        guard modifiedAt != lastCasesModifiedAt else { return }
        loadCases()
    }

    private func casesModifiedAt() -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: casesURL.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    private func countCases(in text: String) -> Int {
        let usableLines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("### ") || !trimmed.hasPrefix("#")
            }
        let markerCount = usableLines
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("### ") }
            .count
        if markerCount > 0 { return markerCount }
        return usableLines
            .joined(separator: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    private func loadModelSelections() {
        selectedTranslatorModels = loadModelSelection(key: translatorModelsKey, fallback: [RusToPromptSettingsStore.defaultTranslator])
        selectedImproverModels = loadModelSelection(key: improverModelsKey, fallback: [RusToPromptSettingsStore.defaultAnalyzer])
    }

    private func loadConfidenceModel() {
        let stored = UserDefaults.standard.string(forKey: confidenceModelKey) ?? RusToPromptSettingsStore.defaultConfidence
        selectedConfidenceModel = stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? RusToPromptSettingsStore.defaultConfidence : stored
    }

    private func loadLocalConfidenceModels() {
        guard let data = UserDefaults.standard.data(forKey: localConfidenceModelsKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            selectedLocalConfidenceModels = ["qwen3:30b-a3b", "qwen3-coder:30b-a3b-q4_K_M"]
            return
        }
        let models = decoded
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        selectedLocalConfidenceModels = Array(models.prefix(2))
        if selectedLocalConfidenceModels.isEmpty {
            selectedLocalConfidenceModels = ["qwen3:30b-a3b", "qwen3-coder:30b-a3b-q4_K_M"]
        }
    }

    private func loadHybridConfidence() {
        if UserDefaults.standard.object(forKey: hybridConfidenceKey) == nil {
            useHybridConfidence = true
            return
        }
        useHybridConfidence = UserDefaults.standard.bool(forKey: hybridConfidenceKey)
    }

    private func loadConfidenceBatchSize() {
        let stored = UserDefaults.standard.integer(forKey: confidenceBatchSizeKey)
        selectedConfidenceBatchSize = [1, 5, 10, 20].contains(stored) ? stored : 10
    }

    private func loadBenchmarkMode() {
        let stored = UserDefaults.standard.string(forKey: benchmarkModeKey)
        selectedBenchmarkMode = TestBenchmarkMode.allCases.first { $0.cliValue == stored || $0.rawValue == stored } ?? .staged
    }

    private func loadModelSelection(key: String, fallback: Set<String>) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return fallback
        }
        let selected = Set(decoded.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        return selected.isEmpty ? fallback : selected
    }

    private func saveModelSelection(_ selection: Set<String>, key: String) {
        let models = Array(selection).sorted()
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func saveConfidenceModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: confidenceModelKey)
    }

    private func saveLocalConfidenceModels() {
        if let data = try? JSONEncoder().encode(selectedLocalConfidenceModels) {
            UserDefaults.standard.set(data, forKey: localConfidenceModelsKey)
        }
    }

    private func saveHybridConfidence(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: hybridConfidenceKey)
    }

    private func toggleLocalConfidenceModel(_ model: String) {
        if let index = selectedLocalConfidenceModels.firstIndex(of: model) {
            selectedLocalConfidenceModels.remove(at: index)
        } else {
            if selectedLocalConfidenceModels.count >= 2 {
                selectedLocalConfidenceModels.removeFirst()
            }
            selectedLocalConfidenceModels.append(model)
        }
        saveLocalConfidenceModels()
    }

    private func saveConfidenceBatchSize(_ size: Int) {
        UserDefaults.standard.set(size, forKey: confidenceBatchSizeKey)
    }

    private func saveBenchmarkMode(_ mode: TestBenchmarkMode) {
        UserDefaults.standard.set(mode.cliValue, forKey: benchmarkModeKey)
    }

    private func refreshCaseFiles() {
        try? FileManager.default.createDirectory(at: casesDirectoryURL, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: casesDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        caseFiles = files
            .filter { $0.pathExtension.lowercased() == "txt" }
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
    }

    private func migrateLegacyCaseFilesIfNeeded() {
        let fileManager = FileManager.default
        let scriptsURL = casesDirectoryURL.deletingLastPathComponent()
        guard let legacyFiles = try? fileManager.contentsOfDirectory(
            at: scriptsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        do {
            try fileManager.createDirectory(at: casesDirectoryURL, withIntermediateDirectories: true)
            for legacyFile in legacyFiles where legacyFile.pathExtension.lowercased() == "txt" {
                let proposedDestination = casesDirectoryURL.appendingPathComponent(legacyFile.lastPathComponent)
                let destination = uniqueCaseFileURL(for: proposedDestination)
                try fileManager.moveItem(at: legacyFile, to: destination)
            }
        } catch {
            statusText = "Could not migrate test files: \(error.localizedDescription)"
        }
    }

    private func uniqueCaseFileURL(for url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return url
        }

        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for index in 1...999 {
            let candidateName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent("\(base)-\(UUID().uuidString).\(ext)")
    }

    private func loadSelectedCasesFile() {
        let stored = UserDefaults.standard.string(forKey: casesFileKey)
        if let stored,
           caseFiles.contains(where: { $0.lastPathComponent == stored }) {
            selectedCasesFileName = stored
            return
        }

        if caseFiles.contains(where: { $0.lastPathComponent == selectedCasesFileName }) {
            UserDefaults.standard.set(selectedCasesFileName, forKey: casesFileKey)
            return
        }

        if let first = caseFiles.first {
            selectedCasesFileName = first.lastPathComponent
            UserDefaults.standard.set(selectedCasesFileName, forKey: casesFileKey)
            return
        }

        createEmptyCasesFile(named: "rus_to_prompt_cases.txt", selectAfterCreate: true)
    }

    private func selectCasesFile(_ file: URL) {
        selectedCasesFileName = file.lastPathComponent
        UserDefaults.standard.set(selectedCasesFileName, forKey: casesFileKey)
        loadCases()
    }

    private func createEmptyCasesFile() {
        createEmptyCasesFile(named: nextEmptyCasesFileName(), selectAfterCreate: true)
    }

    private func createEmptyCasesFile(named fileName: String, selectAfterCreate: Bool) {
        do {
            try FileManager.default.createDirectory(at: casesDirectoryURL, withIntermediateDirectories: true)
            let newFile = casesDirectoryURL.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: newFile.path) {
                try starterCasesTemplate.write(to: newFile, atomically: true, encoding: .utf8)
            }
            refreshCaseFiles()
            if selectAfterCreate {
                selectCasesFile(newFile)
                statusText = "Created \(newFile.lastPathComponent)"
            }
        } catch {
            statusText = "Could not create test file: \(error.localizedDescription)"
        }
    }

    private var starterCasesTemplate: String {
        """
        # Rus to Prompt test scenarios
        #
        # Add one scenario per block. Use this structure:
        #
        # ### rtp-001 [category-name]
        # Paste the Russian or mixed-language prompt here.
        #
        # Notes:
        # - Remove "# " from the example lines when adding real scenarios.
        # - Keep code blocks, inline code, JSON, URLs, file paths, and commands exactly as input.
        # - Separate scenarios with a blank line.

        """
    }

    private func nextEmptyCasesFileName() -> String {
        let existing = Set(caseFiles.map(\.lastPathComponent))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamped = "rus_to_prompt_cases_\(formatter.string(from: Date())).txt"
        if !existing.contains(timestamped) {
            return timestamped
        }

        for index in 1...999 {
            let candidate = "rus_to_prompt_cases_\(index).txt"
            if !existing.contains(candidate) {
                return candidate
            }
        }
        return "rus_to_prompt_cases_new.txt"
    }

    private func deleteSelectedCasesFile() {
        let file = casesURL
        guard FileManager.default.fileExists(atPath: file.path) else {
            statusText = "Selected test file does not exist"
            refreshCaseFiles()
            loadSelectedCasesFile()
            loadCases()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Delete \(file.lastPathComponent)?"
        alert.informativeText = "This removes the selected test scenarios file from Scripts/rus_to_prompt_tests."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.removeItem(at: file)
            refreshCaseFiles()
            if let next = caseFiles.first {
                selectCasesFile(next)
                statusText = "Deleted \(file.lastPathComponent)"
            } else {
                createEmptyCasesFile(named: "rus_to_prompt_cases.txt", selectAfterCreate: true)
                statusText = "Deleted \(file.lastPathComponent); created empty rus_to_prompt_cases.txt"
            }
        } catch {
            statusText = "Could not delete \(file.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func startAllTests() {
        loadCases()
        guard canStartTests else {
            currentTestStatus = runReadinessText
            return
        }

        let translators = Array(selectedTranslatorModels).sorted()
        let improvers = Array(selectedImproverModels).sorted()
        currentRunIndex = 0
        totalRunCount = max(transformOperationCount, 1)
        completedCases = 0
        totalCasesToRun = transformOperationCount
        progressValue = 0
        currentCaseID = "Starting"
        currentStage = "Queued"
        currentStageStartedAt = Date()
        currentStageElapsedSeconds = 0
        currentTestStatus = "Starting"
        currentModelPair = selectedBenchmarkMode == .translation
            ? "\(translators.count) translator(s)"
            : "\(translators.count) x \(improvers.count)"
        progressLines = []
        rawProgressLines = []
        currentProgressEvent = nil
        runStartedAt = Date()
        rejectedTranslationCount = 0
        skippedImproverCount = 0
        confidenceBatchesStarted = 0
        confidenceBatchesFinished = 0
        rejectedTranslationKeys = []
        translationGateState = "Pending"
        resultRows = []
        resultRunRows = []
        resultPromptByCaseID = [:]
        selectedResultRowID = nil
        selectedRunRowID = nil
        resultsStatusText = "Running"
        processOutputBuffer = ""
        isRunningTests = true
        selectedOutputTab = .progress
        runBenchmarkTests(translators: translators, improvers: improvers)
    }

    private func stopTests() {
        activeTestProcess?.terminate()
        activeTestProcess = nil
        isRunningTests = false
        currentStage = "Stopped"
        currentStageStartedAt = Date()
        currentStageElapsedSeconds = 0
        currentTestStatus = "Stopped"
        currentProgressEvent = nil
        appendProgressLine("Stopped by user")
    }

    private func runBenchmarkTests(translators: [String], improvers: [String]) {
        currentStage = "Starting"
        currentTestStatus = "\(selectedBenchmarkMode.rawValue) run"
        currentCaseID = "-"
        processOutputBuffer = ""

        let outDir = repoRootURL
            .appendingPathComponent(".stress")
            .appendingPathComponent("app-tests-\(runTimestamp())-\(selectedBenchmarkMode.cliValue)")
        lastRunOutputURL = outDir
        saveLastRunOutput(outDir)

        let process = Process()
        process.currentDirectoryURL = repoRootURL
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        var arguments = [
            stressScriptURL.path,
            "--benchmark-mode", selectedBenchmarkMode.cliValue,
            "--cases-file", casesURL.path,
            "--limit", "\(caseCount)",
            "--translator-models"
        ]
        arguments.append(contentsOf: translators)
        if !improvers.isEmpty {
            arguments.append("--analyzer-models")
            arguments.append(contentsOf: improvers)
        }
        let confidenceReferee = selectedConfidenceReferee
        let confidenceWorkersForRun = effectiveConfidenceWorkers
        let confidenceModelForRun = confidenceReferee == "hybrid" ? hybridGeminiFallbackModel : selectedConfidenceModel
        arguments.append(contentsOf: [
            "--confidence-referee", confidenceReferee,
            "--confidence-model", confidenceModelForRun,
            "--confidence-reasoning-effort", RusToPromptSettingsStore.defaultConfidenceReasoning,
            "--confidence-workers", "\(confidenceWorkersForRun)",
            "--confidence-batch-size", "\(selectedConfidenceBatchSize)",
            "--translation-confidence-threshold", "0.75",
            "--codex-bin", codexExecutablePath(),
            "--gemini-bin", geminiExecutablePath(),
            "--codex-stage-reasoning-effort", RusToPromptSettingsStore.defaultConfidenceReasoning,
            "--workers", "1",
            "--out-dir", outDir.path
        ])
        if confidenceReferee == "hybrid" {
            arguments.append("--local-confidence-models")
            arguments.append(contentsOf: Array(selectedLocalConfidenceModels.prefix(2)))
            arguments.append(contentsOf: [
                "--hybrid-confidence-gemini-model", hybridGeminiFallbackModel,
                "--hybrid-confidence-fallback-referee", selectedConfidenceFallbackReferee,
                "--hybrid-confidence-local-threshold", "0.80",
                "--hybrid-confidence-disagreement-threshold", "0.15",
            ])
        }
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SOMA_PROJECT_ROOT")
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PATH"] = codexSearchPath(existing: environment["PATH"])
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                consumeProcessOutput(text)
            }
        }

        process.terminationHandler = { finishedProcess in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                if !processOutputBuffer.isEmpty {
                    consumeProcessOutput("\n")
                }
                activeTestProcess = nil
                if finishedProcess.terminationStatus == 0 {
                    isRunningTests = false
                    currentStage = "Done"
                    currentStageStartedAt = Date()
                    currentStageElapsedSeconds = 0
                    currentTestStatus = "All tests finished"
                    currentCaseID = "-"
                    completedCases = totalCasesToRun
                    progressValue = Double(totalCasesToRun)
                    appendProgressLine("All test runs finished")
                    loadResultsSummary(from: outDir)
                    selectedOutputTab = .results
                } else {
                    isRunningTests = false
                    currentStage = "Failed"
                    currentStageStartedAt = Date()
                    currentStageElapsedSeconds = 0
                    currentTestStatus = "Process exited with code \(finishedProcess.terminationStatus)"
                    appendProgressLine(currentTestStatus)
                    loadResultsSummary(from: outDir)
                }
            }
        }

        do {
            try process.run()
            activeTestProcess = process
            appendProgressLine("Started \(selectedBenchmarkMode.rawValue) run: \(translators.count) translator(s), \(improvers.count) improver(s)")
        } catch {
            isRunningTests = false
            currentStage = "Failed"
            currentStageStartedAt = Date()
            currentStageElapsedSeconds = 0
            currentTestStatus = "Could not start tests: \(error.localizedDescription)"
            appendProgressLine(currentTestStatus)
        }
    }

    private func consumeProcessOutput(_ text: String) {
        processOutputBuffer += text
        let parts = processOutputBuffer.components(separatedBy: .newlines)
        guard parts.count > 1 else { return }
        processOutputBuffer = parts.last ?? ""
        for line in parts.dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            appendRawProgressLine(trimmed)
            if let event = decodeProgressEvent(from: trimmed) {
                updateProgress(from: event)
                appendProgressLine(activityText(for: event))
            } else {
                updateProgress(from: trimmed)
                appendProgressLine(trimmed)
            }
        }
    }

    private func decodeProgressEvent(from line: String) -> TestProgressEvent? {
        guard line.hasPrefix(testProgressEventPrefix) else { return nil }
        let payload = String(line.dropFirst(testProgressEventPrefix.count))
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TestProgressEvent.self, from: data)
    }

    private func updateProgress(from event: TestProgressEvent) {
        currentProgressEvent = event
        if runStartedAt == nil || event.event == "run_start" {
            runStartedAt = Date()
        }
        if let total = event.totalOperations {
            totalCasesToRun = max(totalCasesToRun, total)
        }
        if let operation = event.operationIndex {
            currentRunIndex = min(max(operation, 0), max(totalCasesToRun, operation))
        }
        if let caseID = event.caseID, !caseID.isEmpty {
            currentCaseID = caseID
        }
        if let translator = event.translatorModel, let analyzer = event.analyzerModel {
            currentModelPair = "\(translator) -> \(analyzer)"
        } else if let translator = event.translatorModel {
            currentModelPair = translator
        }

        setCurrentStage(displayStage(for: event))

        switch event.event {
        case "run_start":
            currentTestStatus = "Run queued"
            completedCases = 0
            progressValue = 0
        case "stage_start":
            currentTestStatus = operationStatusText(for: event)
            if event.stage == "translating" {
                translationGateState = "Pending"
            }
            let base = Double(max((event.operationIndex ?? 1) - 1, 0))
            progressValue = min(base + stageFraction(event.stage), Double(max(totalCasesToRun, 1)))
        case "stage_complete":
            currentTestStatus = operationStatusText(for: event)
            let base = Double(max((event.operationIndex ?? 1) - 1, 0))
            progressValue = min(base + stageFraction(event.stage) + 0.04, Double(max(totalCasesToRun, 1)))
        case "translation_gate":
            currentTestStatus = event.status == "rejected" ? "Translation rejected; improvers skipped" : "Translation accepted"
            if event.status == "rejected" {
                translationGateState = "Rejected"
                let key = "\(event.caseID ?? "-")|\(event.translatorModel ?? "-")"
                if rejectedTranslationKeys.insert(key).inserted {
                    rejectedTranslationCount += 1
                    skippedImproverCount += selectedImproverModels.count
                }
            } else {
                translationGateState = "Accepted"
            }
            let base = Double(max((event.operationIndex ?? 1) - 1, 0))
            progressValue = min(base + stageFraction(event.stage), Double(max(totalCasesToRun, 1)))
        case "confidence_batch_start":
            confidenceBatchesStarted += 1
            if event.stage.contains("translation_confidence") {
                translationGateState = "Checking"
            }
            currentTestStatus = batchStatusText(for: event, verb: "Checking")
            let base = Double(max((event.operationIndex ?? 1) - 1, 0))
            progressValue = min(base + stageFraction(event.stage), Double(max(totalCasesToRun, 1)))
        case "confidence_batch_complete":
            confidenceBatchesFinished += 1
            currentTestStatus = batchStatusText(for: event, verb: "Checked")
            let base = Double(max((event.operationIndex ?? 1) - 1, 0))
            progressValue = min(base + stageFraction(event.stage) + 0.04, Double(max(totalCasesToRun, 1)))
        case "result_write":
            currentTestStatus = "Saved result"
            completedCases = min(completedCases + 1, totalCasesToRun)
            progressValue = Double(completedCases)
        case "run_finished":
            currentTestStatus = "All tests finished"
            completedCases = totalCasesToRun
            progressValue = Double(totalCasesToRun)
        default:
            currentTestStatus = operationStatusText(for: event)
        }
    }

    private func updateProgress(from line: String) {
        let tokens = line.split(separator: " ").map(String.init)
        if let progressToken = tokens.first(where: { $0.contains("/") }),
           let slashIndex = progressToken.firstIndex(of: "/"),
           let current = Int(progressToken[..<slashIndex]),
           let total = Int(progressToken[progressToken.index(after: slashIndex)...]) {
            currentRunIndex = current
            totalCasesToRun = max(totalCasesToRun, total)
            let stageToken = tokens.first(where: { $0.hasPrefix("stage=") })
            if let stageToken {
                let rawStage = String(stageToken.dropFirst("stage=".count))
                let displayStage = rawStage
                    .replacingOccurrences(of: "_", with: " ")
                    .capitalized
                setCurrentStage(displayStage)
                completedCases = min(max(current - 1, 0), totalCasesToRun)
                progressValue = min(
                    Double(max(current - 1, 0)) + stageFraction(rawStage),
                    Double(max(totalCasesToRun, 1))
                )
            } else {
                setCurrentStage("Completed operation")
                completedCases = min(current, totalCasesToRun)
                progressValue = Double(completedCases)
            }
            currentTestStatus = "Operation \(current)/\(total)"
        }

        if let caseToken = tokens.dropFirst(2).first,
           caseToken.hasPrefix("rtp-") || caseToken.hasPrefix("case-") {
            currentCaseID = caseToken
        }

        let translator = tokens.first(where: { $0.hasPrefix("translator=") })?.dropFirst("translator=".count)
        let analyzer = (
            tokens.first(where: { $0.hasPrefix("improver=") })?.dropFirst("improver=".count)
            ?? tokens.first(where: { $0.hasPrefix("analyzer=") })?.dropFirst("analyzer=".count)
        )
        if let translator, let analyzer {
            currentModelPair = "\(translator) -> \(analyzer)"
        } else if let translator {
            currentModelPair = String(translator)
        }
    }

    private func setCurrentStage(_ stage: String) {
        guard currentStage != stage else { return }
        currentStage = stage
        currentStageStartedAt = Date()
        currentStageElapsedSeconds = 0
    }

    private func displayStage(for event: TestProgressEvent) -> String {
        switch event.stage {
        case "queued":
            return "Queued"
        case "translating":
            return "Translating"
        case "translation_confidence", "translation_confidence_batch":
            return "Translation Check"
        case "translation_rejected":
            return "Translation Rejected"
        case "analyzing":
            return "Improving"
        case "improve_confidence_batch":
            return "Improve Confidence"
        case "overall_confidence_batch":
            return "Overall Confidence"
        case "writing_result":
            return "Saving"
        case "done":
            return "Done"
        case "failed":
            return "Failed"
        default:
            return event.stage
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    private func operationStatusText(for event: TestProgressEvent) -> String {
        if let operation = event.operationIndex, let total = event.totalOperations, total > 0 {
            return "Operation \(operation)/\(total)"
        }
        return event.status?.capitalized ?? currentTestStatus
    }

    private func batchStatusText(for event: TestProgressEvent, verb: String) -> String {
        let batch = {
            if let index = event.batchIndex, let total = event.batchTotal {
                return " batch \(index)/\(total)"
            }
            return " confidence batch"
        }()
        let size = event.batchSize.map { " with \($0) item(s)" } ?? ""
        return "\(verb)\(batch)\(size)"
    }

    private func activityText(for event: TestProgressEvent) -> String {
        let modelText = {
            if let translator = event.translatorModel, let analyzer = event.analyzerModel {
                return "\(translator) -> \(analyzer)"
            }
            if let translator = event.translatorModel {
                return translator
            }
            return ""
        }()
        let caseText = event.caseID.map { "\($0) " } ?? ""
        let confidence = event.confidence.map { String(format: " conf %.2f", $0) } ?? ""
        let suffix = modelText.isEmpty ? "" : " · \(modelText)"

        switch event.event {
        case "run_start":
            return "Run started with \(event.totalOperations ?? totalCasesToRun) operations"
        case "stage_start":
            return "\(caseText)\(displayStage(for: event)) started\(suffix)"
        case "stage_complete":
            return "\(caseText)\(displayStage(for: event)) finished: \(event.status ?? "unknown")\(suffix)"
        case "translation_gate":
            return "\(caseText)translation gate \(event.status ?? "unknown")\(confidence)\(suffix)"
        case "confidence_batch_start":
            return "\(caseText)\(displayStage(for: event)) started \(event.batchIndex ?? 1)/\(event.batchTotal ?? 1), \(event.batchSize ?? 0) item(s)\(suffix)"
        case "confidence_batch_complete":
            return "\(caseText)\(displayStage(for: event)) finished \(event.batchIndex ?? 1)/\(event.batchTotal ?? 1): \(event.status ?? "unknown")\(suffix)"
        case "result_write":
            return "\(caseText)saved result: \(event.status ?? "unknown")\(suffix)"
        case "run_finished":
            return "Run finished"
        default:
            return "\(caseText)\(displayStage(for: event)): \(event.status ?? "updated")\(suffix)"
        }
    }

    private func stageFraction(_ stage: String) -> Double {
        switch stage {
        case "translating":
            return 0.08
        case "analyzing":
            return 0.22
        case "translation_confidence", "translation_confidence_batch":
            return 0.45
        case "translation_rejected":
            return 0.90
        case "improve_confidence", "improve_confidence_batch":
            return 0.65
        case "overall_confidence", "overall_confidence_batch":
            return 0.85
        case "writing_result":
            return 0.96
        default:
            return 0
        }
    }

    private func appendProgressLine(_ line: String) {
        progressLines.append(line)
        if progressLines.count > 40 {
            progressLines.removeFirst(progressLines.count - 40)
        }
    }

    private func appendRawProgressLine(_ line: String) {
        rawProgressLines.append(line)
        if rawProgressLines.count > 160 {
            rawProgressLines.removeFirst(rawProgressLines.count - 160)
        }
    }

    private func loadResultsSummary(from outDir: URL) {
        let summaryURL = outDir.appendingPathComponent("summary.json")
        do {
            lastRunOutputURL = outDir
            saveLastRunOutput(outDir)
            let data = try Data(contentsOf: summaryURL)
            let decoded = try JSONDecoder().decode(TestSummaryEnvelope.self, from: data)
            resultRows = decoded.modelCombinations.sorted { lhs, rhs in
                if lhs.overallConfidence.avg == rhs.overallConfidence.avg {
                    return lhs.comboID < rhs.comboID
                }
                return (lhs.overallConfidence.avg ?? -1) > (rhs.overallConfidence.avg ?? -1)
            }
            selectedResultRowID = resultRows.first?.id
            loadResultRuns(from: outDir)
            let operationCount = decoded.total ?? resultRunRows.count
            let issueText = summaryIssueText(decoded)
            resultsStatusText = issueText.isEmpty
                ? "Loaded \(operationCount) operations / \(resultRows.count) combinations"
                : "Loaded \(operationCount) operations / \(resultRows.count) combinations · \(issueText)"
            if decoded.runStatus == "completed_with_issues" || decoded.success == false {
                setCurrentStage(decoded.runStatus == "failed" ? "Failed" : "Done with issues")
                currentTestStatus = issueText.isEmpty ? "Run completed with issues" : issueText
            }
        } catch {
            if !loadPartialResults(from: outDir) {
                resultsStatusText = "Could not load summary: \(error.localizedDescription)"
            }
        }
    }

    private func summaryIssueText(_ summary: TestSummaryEnvelope) -> String {
        var parts: [String] = []
        if let runStatus = summary.runStatus, runStatus != "completed" {
            parts.append(runStatus.replacingOccurrences(of: "_", with: " "))
        }
        if let confidenceFailedCount = summary.confidenceFailedCount, confidenceFailedCount > 0 {
            parts.append("\(confidenceFailedCount) confidence failed")
        }
        if let externalErrorCounts = summary.externalErrorCounts, !externalErrorCounts.isEmpty {
            let text = externalErrorCounts
                .sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
            parts.append(text)
        }
        if let issueCounts = summary.issueCounts {
            let important = ["interrupted", "pipeline_failed", "degraded", "translation_rejected", "low_confidence", "incomplete_operations"]
                .compactMap { key -> String? in
                    guard let value = issueCounts[key], value > 0 else { return nil }
                    return "\(key.replacingOccurrences(of: "_", with: " ")) \(value)"
                }
            parts.append(contentsOf: important)
        }
        return parts.joined(separator: " · ")
    }

    @discardableResult
    private func loadPartialResults(from outDir: URL) -> Bool {
        lastRunOutputURL = outDir
        saveLastRunOutput(outDir)
        loadResultRuns(from: outDir)
        guard !resultRunRows.isEmpty else {
            resultRows = []
            selectedResultRowID = nil
            return false
        }
        resultRows = []
        selectedResultRowID = nil
        selectedResultsMode = .byCase
        resultsStatusText = "Loaded partial \(resultRunRows.count) checked operation(s); summary is not finished"
        return true
    }

    private func loadModelStats() {
        guard !isLoadingModelStats else { return }
        let scriptURL = modelStatsScriptURL
        let stressURL = stressDirectoryURL
        let rootURL = repoRootURL
        let baseEnvironment = ProcessInfo.processInfo.environment
        let searchPath = codexSearchPath(existing: baseEnvironment["PATH"])
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            modelStats = nil
            modelStatsStatusText = "Stats script not found: \(scriptURL.path)"
            return
        }

        isLoadingModelStats = true
        modelStatsStatusText = "Loading model stats"

        DispatchQueue.global(qos: .userInitiated).async {
            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("soma-model-stats-\(UUID().uuidString)", isDirectory: true)
            let stdoutURL = tempDirectory.appendingPathComponent("stdout.json")
            let stderrURL = tempDirectory.appendingPathComponent("stderr.log")

            let process = Process()
            process.currentDirectoryURL = rootURL
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [
                scriptURL.path,
                "--stress-dir", stressURL.path
            ]

            var environment = baseEnvironment
            environment.removeValue(forKey: "SOMA_PROJECT_ROOT")
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            environment["PATH"] = searchPath
            process.environment = environment

            let stdoutHandle: FileHandle
            let stderrHandle: FileHandle
            do {
                try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
                FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
                stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
                stderrHandle = try FileHandle(forWritingTo: stderrURL)
                process.standardOutput = stdoutHandle
                process.standardError = stderrHandle
            } catch {
                DispatchQueue.main.async {
                    self.modelStats = nil
                    self.modelStatsStatusText = "Could not prepare stats output: \(error.localizedDescription)"
                    self.isLoadingModelStats = false
                }
                return
            }

            do {
                try process.run()
                process.waitUntilExit()
                try? stdoutHandle.close()
                try? stderrHandle.close()
                defer {
                    try? FileManager.default.removeItem(at: tempDirectory)
                }

                let data = (try? Data(contentsOf: stdoutURL)) ?? Data()
                let stderrText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
                if process.terminationStatus != 0 {
                    let stdoutText = String(data: data, encoding: .utf8) ?? ""
                    let text = [stderrText, stdoutText]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    DispatchQueue.main.async {
                        self.isLoadingModelStats = false
                        self.modelStatsStatusText = "Stats failed: \(text)"
                    }
                    return
                }
                let decoded = try JSONDecoder().decode(TestModelStatsEnvelope.self, from: data)
                DispatchQueue.main.async {
                    self.modelStats = decoded
                    self.selectedTranslationStatsID = decoded.translationModels.first?.id
                    self.selectedImproverStatsID = decoded.improverModels.first?.id
                    self.modelStatsStatusText = "Loaded \(decoded.translationModels.count) translation model(s), \(decoded.improverModels.count) improver model(s)"
                    self.isLoadingModelStats = false
                }
            } catch {
                try? stdoutHandle.close()
                try? stderrHandle.close()
                let stderrText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: tempDirectory)
                DispatchQueue.main.async {
                    self.modelStats = nil
                    let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.modelStatsStatusText = detail.isEmpty
                        ? "Could not load model stats: \(error.localizedDescription)"
                        : "Could not load model stats: \(error.localizedDescription)\n\(detail)"
                    self.isLoadingModelStats = false
                }
            }
        }
    }

    private func loadModelStatsIfNeeded() {
        guard modelStats == nil, !isLoadingModelStats else { return }
        loadModelStats()
    }

    private func openStressLogsFolder() {
        try? FileManager.default.createDirectory(at: stressDirectoryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(stressDirectoryURL)
    }

    private func loadResultRuns(from outDir: URL) {
        let resultsURL = outDir.appendingPathComponent("results.jsonl")
        do {
            resultPromptByCaseID = loadPromptManifest(from: outDir)
            let text = try String(contentsOf: resultsURL, encoding: .utf8)
            let decoder = JSONDecoder()
            resultRunRows = text
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> TestRunResult? in
                    guard let data = String(line).data(using: .utf8) else { return nil }
                    return try? decoder.decode(TestRunResult.self, from: data)
                }
                .sorted {
                    if $0.caseID == $1.caseID {
                        let lhs = effectiveConfidence($0.overallConfidence)
                        let rhs = effectiveConfidence($1.overallConfidence)
                        if lhs == rhs { return $0.comboID < $1.comboID }
                        return lhs > rhs
                    }
                    return $0.caseID < $1.caseID
                }
            selectedRunRowID = resultRunRows.first?.id
        } catch {
            resultRunRows = []
            resultPromptByCaseID = [:]
        }
    }

    private func loadPromptManifest(from outDir: URL) -> [String: String] {
        let manifestURL = outDir.appendingPathComponent("prompts.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([TestPromptManifestCase].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0.prompt) })
    }

    private func saveLastRunOutput(_ outDir: URL) {
        UserDefaults.standard.set(outDir.path, forKey: lastRunOutputKey)
    }

    private func loadLastResultsIfAvailable() {
        guard !isRunningTests else { return }
        if let storedPath = UserDefaults.standard.string(forKey: lastRunOutputKey) {
            let storedURL = URL(fileURLWithPath: storedPath)
            if FileManager.default.fileExists(atPath: storedURL.appendingPathComponent("summary.json").path) {
                loadResultsSummary(from: storedURL)
                return
            }
            if hasNonEmptyResults(at: storedURL), loadPartialResults(from: storedURL) {
                return
            }
        }

        if let latest = latestResultsOutputDirectory() {
            loadResultsSummary(from: latest)
        }
    }

    private func hasNonEmptyResults(at directory: URL) -> Bool {
        let resultsURL = directory.appendingPathComponent("results.jsonl")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resultsURL.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    private func latestResultsOutputDirectory() -> URL? {
        let stressURL = repoRootURL.appendingPathComponent(".stress")
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: stressURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else {
            return nil
        }

        return directories
            .filter { directory in
                guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey]),
                      values.isDirectory == true else { return false }
                return FileManager.default.fileExists(atPath: directory.appendingPathComponent("summary.json").path)
                    || hasNonEmptyResults(at: directory)
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
            .first
    }

    private func codexExecutablePath() -> String {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ]
        if let existing = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return existing
        }
        return "codex"
    }

    private func geminiExecutablePath() -> String {
        let candidates = [
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini"
        ]
        if let existing = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return existing
        }
        return "gemini"
    }

    private func codexSearchPath(existing: String?) -> String {
        let required = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        let existingParts = (existing ?? "").split(separator: ":").map(String.init)
        let merged = required + existingParts.filter { !required.contains($0) }
        return merged.joined(separator: ":")
    }

    private func runTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars).replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
    }

    private func selectedModelsSummary(_ selection: Set<String>) -> String {
        let models = Array(selection).sorted()
        if models.isEmpty { return "No models selected" }
        return models.joined(separator: ", ")
    }

    private func mergePresets(_ presets: [RusToPromptModelPreset]) -> [RusToPromptModelPreset] {
        var seen = Set<String>()
        var merged: [RusToPromptModelPreset] = []
        for preset in presets {
            let key = preset.model.lowercased()
            guard !seen.contains(key) else { continue }
            merged.append(preset)
            seen.insert(key)
        }
        return merged
    }

    private func addCustomModel(
        _ customModel: Binding<String>,
        selection: Binding<Set<String>>,
        storageKey: String
    ) {
        let model = customModel.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        selection.wrappedValue.insert(model)
        saveModelSelection(selection.wrappedValue, key: storageKey)
        customModel.wrappedValue = ""
    }

    private func isCodexModelName(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("gpt-")
            || normalized.hasPrefix("o1")
            || normalized.hasPrefix("o3")
            || normalized.hasPrefix("o4")
            || normalized.hasPrefix("codex-")
    }

    private func isGeminiModelName(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("gemini-")
            || normalized.hasPrefix("auto-gemini")
            || normalized.hasPrefix("gemma-4-")
    }

    private func adHocPreset(for model: String) -> RusToPromptModelPreset {
        if isGeminiModelName(model) {
            return RusToPromptModelPreset(
                model: model,
                quality: "Unknown",
                speed: "Unknown",
                ram: "0 GB",
                detail: "Custom Gemini CLI model. It will run through the Gemini provider if the CLI account can access it.",
                recommended: false,
                provider: "gemini"
            )
        }
        if isCodexModelName(model) {
            return RusToPromptModelPreset(
                model: model,
                quality: "Unknown",
                speed: "Unknown",
                ram: "0 GB",
                detail: "Custom Codex CLI model. It will run through Codex with the configured stage reasoning effort.",
                recommended: false,
                isCodex: true
            )
        }
        return RusToPromptModelPreset(
            model: model,
            quality: "Unknown",
            speed: "Unknown",
            ram: "Custom",
            detail: "Custom local Ollama model. Install it in Ollama before running tests.",
            recommended: false
        )
    }

    private func statsRows(for role: TestModelRole) -> [TestModelRoleStats] {
        guard let modelStats else { return [] }
        switch role {
        case .translator:
            return modelStats.translationModels
        case .improver:
            return modelStats.improverModels
        }
    }

    private func speedLabels(for rows: [TestModelRoleStats]) -> [String: String] {
        let timedRows = rows
            .filter { ($0.avgSeconds ?? 0) > 0 }
            .sorted {
                let lhs = $0.avgSeconds ?? .greatestFiniteMagnitude
                let rhs = $1.avgSeconds ?? .greatestFiniteMagnitude
                if lhs != rhs { return lhs < rhs }
                return $0.model.localizedStandardCompare($1.model) == .orderedAscending
            }
        let count = timedRows.count
        guard count > 0 else { return [:] }

        var labels: [String: String] = [:]
        for (index, row) in timedRows.enumerated() {
            let percentile = Double(index + 1) / Double(count)
            let label: String
            if percentile <= 0.25 {
                label = "Fastest"
            } else if percentile <= 0.50 {
                label = "Fast"
            } else if percentile <= 0.75 {
                label = "Balanced"
            } else {
                label = "Slow"
            }
            labels[row.model.lowercased()] = label
        }
        return labels
    }

    private func qualityLabel(for stats: TestModelRoleStats?) -> String {
        guard let stats else { return "No data" }
        let attempts = max(stats.attempts, 0)
        let pipelineFailRate = attempts > 0 ? Double(stats.pipelineFailedCount) / Double(attempts) : 0
        let confidenceFailRate = attempts > 0 ? Double(stats.confidenceFailedCount) / Double(attempts) : 0

        if attempts > 0 && (pipelineFailRate >= 0.50 || (stats.confidenceCount == 0 && (stats.pipelineFailedCount > 0 || stats.confidenceFailedCount > 0))) {
            return "Broken"
        }
        guard let confidence = stats.avgConfidence else { return "No data" }
        if confidence < 0.80 || pipelineFailRate > 0.15 {
            return "Risk"
        }
        if confidence >= 0.89 && pipelineFailRate <= 0.025 && confidenceFailRate <= 0.05 {
            return "Best"
        }
        if confidence >= 0.86 && pipelineFailRate <= 0.075 {
            return "High"
        }
        return "Good"
    }

    private func benchmarkDetail(for preset: RusToPromptModelPreset, stats: TestModelRoleStats?, quality: String, speed: String) -> String {
        guard let stats else {
            return [
                preset.detail,
                "No benchmark data yet.",
                "Run translation/staged tests to rank this model."
            ]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        }

        let attempts = max(stats.attempts, 0)
        let pipelineFailRate = attempts > 0 ? Double(stats.pipelineFailedCount) / Double(attempts) : 0
        let confidenceFailRate = attempts > 0 ? Double(stats.confidenceFailedCount) / Double(attempts) : 0
        return [
            preset.detail,
            "Benchmark quality: \(quality); speed: \(speed).",
            "Attempts \(stats.attempts), confidence scores \(stats.confidenceCount), avg \(formatConfidence(stats.avgConfidence)), median \(formatConfidence(stats.medianConfidence)), min \(formatConfidence(stats.minConfidence)).",
            "Low \(stats.lowConfidenceCount), confidence failed \(stats.confidenceFailedCount) (\(formatPercent(confidenceFailRate)), pipeline failed \(stats.pipelineFailedCount) (\(formatPercent(pipelineFailRate)), degraded \(stats.degradedCount).",
            "Average runtime \(formatOptionalSeconds(stats.avgSeconds)); last tested \(shortDateTime(stats.lastTestedAt))."
        ]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "\n")
    }

    private func rankedModelPresets(
        role: TestModelRole,
        knownPresets: [RusToPromptModelPreset],
        sort: TestModelSort,
        extraModels: Set<String> = []
    ) -> [TestRankedModelPreset] {
        let presets = installedModelPresets(knownPresets: knownPresets, extraModels: extraModels)
        let statsRows = statsRows(for: role)
        var statsByModel: [String: TestModelRoleStats] = [:]
        for row in statsRows {
            statsByModel[row.model.lowercased()] = row
        }
        let speedByModel = speedLabels(for: statsRows)

        let ranked = presets.map { preset in
            let stats = statsByModel[preset.model.lowercased()]
            let quality = qualityLabel(for: stats)
            let speed = stats == nil ? "No data" : (speedByModel[preset.model.lowercased()] ?? "No data")
            return TestRankedModelPreset(
                preset: preset,
                stats: stats,
                quality: quality,
                speed: speed,
                detail: benchmarkDetail(for: preset, stats: stats, quality: quality, speed: speed)
            )
        }

        return ranked.sorted { lhs, rhs in
            switch sort {
            case .smart:
                if lhs.hasStats != rhs.hasStats { return lhs.hasStats }
                if lhs.isBroken != rhs.isBroken { return !lhs.isBroken }
                if lhs.qualityRank != rhs.qualityRank { return lhs.qualityRank > rhs.qualityRank }
                let lhsConfidence = lhs.avgConfidence ?? -1
                let rhsConfidence = rhs.avgConfidence ?? -1
                if lhsConfidence != rhsConfidence { return lhsConfidence > rhsConfidence }
                let lhsFailures = lhs.pipelineFailedCount + lhs.confidenceFailedCount + lhs.lowConfidenceCount
                let rhsFailures = rhs.pipelineFailedCount + rhs.confidenceFailedCount + rhs.lowConfidenceCount
                if lhsFailures != rhsFailures { return lhsFailures < rhsFailures }
                let lhsSeconds = lhs.avgSeconds ?? .greatestFiniteMagnitude
                let rhsSeconds = rhs.avgSeconds ?? .greatestFiniteMagnitude
                if lhsSeconds != rhsSeconds { return lhsSeconds < rhsSeconds }
                if lhs.attempts != rhs.attempts { return lhs.attempts > rhs.attempts }
                return lhs.preset.model.localizedStandardCompare(rhs.preset.model) == .orderedAscending
            case .quality:
                if lhs.qualityRank != rhs.qualityRank { return lhs.qualityRank > rhs.qualityRank }
                let lhsConfidence = lhs.avgConfidence ?? -1
                let rhsConfidence = rhs.avgConfidence ?? -1
                if lhsConfidence != rhsConfidence { return lhsConfidence > rhsConfidence }
                return lhs.preset.model.localizedStandardCompare(rhs.preset.model) == .orderedAscending
            case .speed:
                let lhsSeconds = lhs.avgSeconds ?? .greatestFiniteMagnitude
                let rhsSeconds = rhs.avgSeconds ?? .greatestFiniteMagnitude
                if lhsSeconds != rhsSeconds { return lhsSeconds < rhsSeconds }
                if lhs.qualityRank != rhs.qualityRank { return lhs.qualityRank > rhs.qualityRank }
                return lhs.preset.model.localizedStandardCompare(rhs.preset.model) == .orderedAscending
            case .name:
                return lhs.preset.model.localizedStandardCompare(rhs.preset.model) == .orderedAscending
            }
        }
    }

    private func installedModelPresets(
        knownPresets: [RusToPromptModelPreset],
        extraModels: Set<String> = []
    ) -> [RusToPromptModelPreset] {
        var knownByName: [String: RusToPromptModelPreset] = [:]
        for preset in knownPresets {
            let key = preset.model.lowercased()
            if knownByName[key] == nil {
                knownByName[key] = preset
            }
        }
        var seen = Set<String>()
        var presets = ollama.installedModels.map { installed in
            seen.insert(installed.name.lowercased())
            if let known = knownByName[installed.name.lowercased()] {
                return RusToPromptModelPreset(
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
            return RusToPromptModelPreset(
                model: installed.name,
                quality: "Unknown",
                speed: "Unknown",
                ram: installed.formattedSize.isEmpty ? installed.parameterSize : installed.formattedSize,
                detail: installed.displayDetail.isEmpty ? "Installed Ollama model." : installed.displayDetail,
                recommended: false
            )
        }
        for preset in knownPresets where preset.isCodex || preset.isGemini {
            let key = preset.model.lowercased()
            if !seen.contains(key) {
                presets.append(preset)
                seen.insert(key)
            }
        }
        for model in extraModels {
            let key = model.lowercased()
            if !seen.contains(key) {
                presets.append(adHocPreset(for: model))
                seen.insert(key)
            }
        }
        return presets
    }

    private func queueLocalModelRows(selected: [String]) -> [RusToPromptModelPreset] {
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

    private func queueItemTone(_ status: RusToPromptQueueItemStatus) -> SomaStatusTone {
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

    private func setQueueLocalConfidenceModels(_ models: [String]) {
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

    private func setQueueConfidenceFallbackReferee(_ fallback: String) {
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

    private func setQueueOnlineConfidenceModel(_ model: String) {
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

    private func queueEffectiveConfidenceReferee(localModels: [String], fallbackReferee: String) -> String {
        if localModels.count >= 2 { return "hybrid" }
        if fallbackReferee == "off" {
            return localModels.isEmpty ? "off" : "local"
        }
        return fallbackReferee
    }

    private func queueConfidenceModelFor(localModels: [String], fallbackReferee: String, onlineModel: String? = nil) -> String {
        if localModels.count == 1 && fallbackReferee == "off" {
            return localModels[0]
        }
        return onlineModel ?? queueManager.settings.confidenceModel
    }

    private func queueDefaultConfidenceModel(for fallbackReferee: String, current: String) -> String {
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

    private func isInstalled(_ model: String) -> Bool {
        ollama.installedModels.contains { $0.name.caseInsensitiveCompare(model) == .orderedSame }
    }

    private func shortModelName(_ model: String) -> String {
        if model.count <= 30 { return model }
        return String(model.prefix(27)) + "..."
    }

    private var localConfidenceModelPresets: [RusToPromptModelPreset] {
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

    private func modelMenuLabel(_ preset: RusToPromptModelPreset) -> String {
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

    private func qualityTone(_ quality: String) -> SomaStatusTone {
        switch quality {
        case "Best", "High": return .good
        case "Good": return .info
        case "Risk": return .warning
        case "Broken": return .danger
        default: return .neutral
        }
    }

    private func speedTone(_ speed: String) -> SomaStatusTone {
        switch speed {
        case "Fast", "Fastest": return .good
        case "Balanced", "Medium": return .info
        case "Slow": return .warning
        default: return .neutral
        }
    }

    private func openCasesInVSCode() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Visual Studio Code", casesURL.path]
        do {
            try process.run()
            statusText = "Opened \(casesURL.lastPathComponent) in VSCode"
        } catch {
            NSWorkspace.shared.open(casesURL)
            statusText = "Opened \(casesURL.lastPathComponent)"
        }
    }
}

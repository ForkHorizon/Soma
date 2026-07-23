import SwiftUI
import AppKit
import Foundation
import Combine

enum TestsViewMode {
    case full   // the full batch-runner page (separate window)
    case queue  // queue-only, as a sidebar route
    case stats  // model-stats-only, as a sidebar route
}

struct TestsView: View {
    var mode: TestsViewMode = .full
    let refreshTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    let translatorModelsKey = "tests.rusToPrompt.translatorModels"

    let improverModelsKey = "tests.rusToPrompt.improverModels"

    let confidenceModelKey = "tests.rusToPrompt.confidenceModel"

    let localConfidenceModelsKey = "tests.rusToPrompt.localConfidenceModels"

    let hybridConfidenceKey = "tests.rusToPrompt.hybridConfidence"

    let confidenceBatchSizeKey = "tests.rusToPrompt.confidenceBatchSize"

    let benchmarkModeKey = "tests.rusToPrompt.benchmarkMode"

    let casesFileKey = "tests.rusToPrompt.casesFile"

    let lastRunOutputKey = "tests.rusToPrompt.lastRunOutputPath"

    let confidenceWorkers = 3

    @ObservedObject var ollama: OllamaManager
    @ObservedObject var queueManager: RusToPromptQueueManager
    @State var caseCount = 0
    @State var statusText = ""
    @State var lastCasesModifiedAt: Date?
    @State var selectedTranslatorModels: Set<String> = []
    @State var selectedImproverModels: Set<String> = []
    @State var selectedConfidenceModel = RusToPromptSettingsStore.defaultConfidence
    @State var selectedLocalConfidenceModels: [String] = ["qwen3:30b-a3b", "qwen3-coder:30b-a3b-q4_K_M"]
    @State var useHybridConfidence = true
    @State var selectedConfidenceBatchSize = 10
    @State var selectedBenchmarkMode: TestBenchmarkMode = .staged
    @State var selectedCasesFileName = "rus_to_prompt_cases.txt"
    @State var caseFiles: [URL] = []
    @State var isRunningTests = false
    @State var activeTestProcess: Process?
    @State var currentRunIndex = 0
    @State var totalRunCount = 0
    @State var completedCases = 0
    @State var totalCasesToRun = 0
    @State var progressValue = 0.0
    @State var currentCaseID = "Idle"
    @State var currentStage = "Idle"
    @State var currentStageStartedAt = Date()
    @State var currentStageElapsedSeconds = 0.0
    @State var currentTestStatus = "Not started"
    @State var currentModelPair = "No active run"
    @State var lastRunOutputURL: URL?
    @State var progressLines: [String] = []
    @State var rawProgressLines: [String] = []
    @State var currentProgressEvent: TestProgressEvent?
    @State var runStartedAt: Date?
    @State var rejectedTranslationCount = 0
    @State var skippedImproverCount = 0
    @State var confidenceBatchesStarted = 0
    @State var confidenceBatchesFinished = 0
    @State var rejectedTranslationKeys: Set<String> = []
    @State var translationGateState = "Pending"
    @State var processOutputBuffer = ""
    @State var selectedOutputTab: TestOutputTab = .progress
    @State var selectedResultsMode: TestResultsMode = .byModel
    @State var resultRows: [TestModelCombinationSummary] = []
    @State var resultRunRows: [TestRunResult] = []
    @State var resultPromptByCaseID: [String: String] = [:]
    @State var resultConfidenceJudgesByItemID: [String: [TestConfidenceJudgeResult]] = [:]
    @State var selectedResultRowID: String?
    @State var selectedRunRowID: String?
    @State var resultsStatusText = "No results yet"
    @State var showModelStats = false
    @State var showQueue = false
    @State var modelStats: TestModelStatsEnvelope?
    @State var modelStatsStatusText = "Not loaded"
    @State var isLoadingModelStats = false
    @State var selectedTranslationStatsID: String?
    @State var selectedImproverStatsID: String?
    @State var translationModelStatsSort: TestModelStatsSort?
    @State var improverModelStatsSort: TestModelStatsSort?
    @State var showTranslatorModels = false
    @State var showImproverModels = false
    @State var showLocalConfidenceModels = false
    @State var showQueueLocalConfidenceModels = false
    @State var showCompletedQueueItems = false
    @State var expandedQueueItemIDs: Set<String> = []
    @State var expandedRunDebugIDs: Set<String> = []
    @State var expandedQueueModelDebugIDs: Set<String> = []
    @State var translatorModelSort: TestModelSort = .smart
    @State var improverModelSort: TestModelSort = .smart
    @State var customTranslatorModel = ""
    @State var customImproverModel = ""


    var body: some View {
        switch mode {
        case .full:
            fullBody
        case .queue:
            queueSheet
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(SomaDesign.pageBackground)
                .onAppear {
                    queueManager.refreshFreeMemory()
                    queueManager.refreshPowerSource()
                    queueManager.startNextIfPossible()
                    ollama.refreshInstalledModels()
                    loadModelStatsIfNeeded()   // candidate panels show benchmark stats from this
                }
                .onChange(of: queueManager.completedCount) { _, _ in loadModelStats() }
        case .stats:
            modelStatsSheet
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(SomaDesign.pageBackground)
                .onAppear { loadModelStats() }
                .onChange(of: queueManager.completedCount) { _, _ in loadModelStats() }
        }
    }

    var fullBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    testCasesPanel
                        .frame(minWidth: 260)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    testTranslatorPanel
                        .frame(minWidth: 260)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    testImproverPanel
                        .frame(minWidth: 260)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                VStack(alignment: .leading, spacing: 12) {
                    testCasesPanel
                    testTranslatorPanel
                    testImproverPanel
                }
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
                .frame(minWidth: 900, minHeight: 680)
                .onAppear {
                    loadModelStats()
                }
        }
        .sheet(isPresented: $showQueue) {
            queueSheet
                .frame(minWidth: 900, minHeight: 680)
                .onAppear {
                    queueManager.refreshFreeMemory()
                    queueManager.refreshPowerSource()
                    queueManager.startNextIfPossible()
                }
        }
    }

    var testTranslatorPanel: some View {
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
    }

    var testImproverPanel: some View {
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
    }

}

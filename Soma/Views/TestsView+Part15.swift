import SwiftUI
import AppKit
import Foundation

extension TestsView {
    func startAllTests() {
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
        currentModelPair =
            selectedBenchmarkMode == .translation
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

    func stopTests() {
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

    func runBenchmarkTests(translators: [String], improvers: [String]) {
        currentStage = "Starting"
        currentTestStatus = "\(selectedBenchmarkMode.rawValue) run"
        currentCaseID = "-"
        processOutputBuffer = ""
        let outDir = benchmarkOutputDirectory()
        lastRunOutputURL = outDir
        saveLastRunOutput(outDir)

        let process = makeBenchmarkProcess(translators: translators, improvers: improvers, outDir: outDir)
        let pipe = Pipe()
        attachBenchmarkOutput(pipe, to: process)
        attachBenchmarkTermination(pipe, to: process, outDir: outDir)
        startBenchmarkProcess(process, translators: translators, improvers: improvers)
    }

    func benchmarkOutputDirectory() -> URL {
        repoRootURL
            .appendingPathComponent(".stress")
            .appendingPathComponent("app-tests-\(runTimestamp())-\(selectedBenchmarkMode.cliValue)")
    }

    func makeBenchmarkProcess(translators: [String], improvers: [String], outDir: URL) -> Process {
        let process = Process()
        process.currentDirectoryURL = repoRootURL
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = benchmarkArguments(translators: translators, improvers: improvers, outDir: outDir)
        process.environment = benchmarkEnvironment()
        return process
    }

    func benchmarkArguments(translators: [String], improvers: [String], outDir: URL) -> [String] {
        var arguments = [
            stressScriptURL.path,
            "--benchmark-mode", selectedBenchmarkMode.cliValue,
            "--cases-file", casesURL.path,
            "--limit", "\(caseCount)",
            "--translator-models",
        ]
        arguments.append(contentsOf: translators)
        if !improvers.isEmpty {
            arguments.append("--analyzer-models")
            arguments.append(contentsOf: improvers)
        }
        arguments.append(contentsOf: benchmarkConfidenceArguments(outDir: outDir))
        return arguments
    }

    func benchmarkConfidenceArguments(outDir: URL) -> [String] {
        let confidenceReferee = selectedConfidenceReferee
        let confidenceWorkersForRun = effectiveConfidenceWorkers
        let confidenceModelForRun = confidenceReferee == "hybrid" ? hybridGeminiFallbackModel : selectedConfidenceModel
        var arguments = [
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
            "--out-dir", outDir.path,
        ]
        if confidenceReferee == "hybrid" {
            arguments.append("--local-confidence-models")
            arguments.append(contentsOf: Array(selectedLocalConfidenceModels.prefix(2)))
            arguments.append(contentsOf: [
                "--hybrid-confidence-online-model", hybridGeminiFallbackModel,
                "--hybrid-confidence-fallback-referee", selectedConfidenceFallbackReferee,
                "--hybrid-confidence-local-threshold", "0.80",
                "--hybrid-confidence-disagreement-threshold", "0.15",
            ])
        }
        return arguments
    }

    func benchmarkEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SOMA_PROJECT_ROOT")
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PATH"] = codexSearchPath(existing: environment["PATH"])
        DeepSeekCredentialStore.apply(to: &environment)
        return environment
    }

    func attachBenchmarkOutput(_ pipe: Pipe, to process: Process) {
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self.consumeProcessOutput(text)
            }
        }
    }

    func attachBenchmarkTermination(_ pipe: Pipe, to process: Process, outDir: URL) {
        process.terminationHandler = { finishedProcess in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.handleBenchmarkFinished(finishedProcess, outDir: outDir)
            }
        }
    }

    func handleBenchmarkFinished(_ finishedProcess: Process, outDir: URL) {
        if !processOutputBuffer.isEmpty {
            consumeProcessOutput("\n")
        }
        activeTestProcess = nil
        if finishedProcess.terminationStatus == 0 {
            markBenchmarkCompleted(outDir: outDir)
        } else {
            markBenchmarkFailed(status: finishedProcess.terminationStatus, outDir: outDir)
        }
    }

    func markBenchmarkCompleted(outDir: URL) {
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
    }

    func markBenchmarkFailed(status: Int32, outDir: URL) {
        isRunningTests = false
        currentStage = "Failed"
        currentStageStartedAt = Date()
        currentStageElapsedSeconds = 0
        currentTestStatus = "Process exited with code \(status)"
        appendProgressLine(currentTestStatus)
        loadResultsSummary(from: outDir)
    }

    func startBenchmarkProcess(_ process: Process, translators: [String], improvers: [String]) {
        do {
            try process.run()
            activeTestProcess = process
            appendProgressLine(
                "Started \(selectedBenchmarkMode.rawValue) run: \(translators.count) translator(s), \(improvers.count) improver(s)")
        } catch {
            isRunningTests = false
            currentStage = "Failed"
            currentStageStartedAt = Date()
            currentStageElapsedSeconds = 0
            currentTestStatus = "Could not start tests: \(error.localizedDescription)"
            appendProgressLine(currentTestStatus)
        }
    }

    func consumeProcessOutput(_ text: String) {
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

    var testProgressEventPrefix: String {
        "SOMA_PROGRESS "
    }

    func decodeProgressEvent(from line: String) -> TestProgressEvent? {
        guard line.hasPrefix(testProgressEventPrefix) else { return nil }
        let payload = String(line.dropFirst(testProgressEventPrefix.count))
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TestProgressEvent.self, from: data)
    }

}

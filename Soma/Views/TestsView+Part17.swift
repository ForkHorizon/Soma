import SwiftUI
import AppKit
import Foundation

struct TestModelStatsRunContext {
    let scriptURL: URL
    let stressURL: URL
    let rootURL: URL
    let environment: [String: String]
}

struct TestModelStatsOutput {
    let tempDirectory: URL
    let stdoutURL: URL
    let stderrURL: URL
    let stdoutHandle: FileHandle
    let stderrHandle: FileHandle

    func close() {
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDirectory)
    }
}

extension TestsView {
    func stageFraction(_ stage: String) -> Double {
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

    func appendProgressLine(_ line: String) {
        progressLines.append(line)
        if progressLines.count > 40 {
            progressLines.removeFirst(progressLines.count - 40)
        }
    }

    func appendRawProgressLine(_ line: String) {
        rawProgressLines.append(line)
        if rawProgressLines.count > 160 {
            rawProgressLines.removeFirst(rawProgressLines.count - 160)
        }
    }

    func loadResultsSummary(from outDir: URL) {
        let summaryURL = outDir.appendingPathComponent("summary.json")
        do {
            lastRunOutputURL = outDir
            saveLastRunOutput(outDir)
            let data = try Data(contentsOf: summaryURL)
            let decoded = try JSONDecoder().decode(TestSummaryEnvelope.self, from: data)
            resultRows = decoded.modelCombinations.sorted { lhs, rhs in
                let lhsQuality = lhs.qualityScore ?? lhs.overallConfidence.avg ?? lhs.translationConfidence.avg ?? -1
                let rhsQuality = rhs.qualityScore ?? rhs.overallConfidence.avg ?? rhs.translationConfidence.avg ?? -1
                if lhsQuality == rhsQuality {
                    return lhs.comboID < rhs.comboID
                }
                return lhsQuality > rhsQuality
            }
            selectedResultRowID = resultRows.first?.id
            loadResultRuns(from: outDir)
            let operationCount = decoded.total ?? resultRunRows.count
            let issueText = summaryIssueText(decoded)
            resultsStatusText =
                issueText.isEmpty
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

    func summaryIssueText(_ summary: TestSummaryEnvelope) -> String {
        var parts: [String] = []
        if let runStatus = summary.runStatus, !["completed", "ok"].contains(runStatus) {
            parts.append(runStatus.replacingOccurrences(of: "_", with: " "))
        }
        if let confidenceFailedCount = summary.confidenceFailedCount, confidenceFailedCount > 0 {
            parts.append("\(confidenceFailedCount) confidence failed")
        }
        if let externalErrorCounts = summary.externalErrorCounts, !externalErrorCounts.isEmpty {
            let text =
                externalErrorCounts
                .sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
            parts.append(text)
        }
        if let issueCounts = summary.issueCounts {
            let important = [
                "interrupted", "pipeline_failed", "degraded", "translation_rejected", "low_confidence", "incomplete_operations",
            ]
            .compactMap { key -> String? in
                guard let value = issueCounts[key], value > 0 else { return nil }
                return "\(key.replacingOccurrences(of: "_", with: " ")) \(value)"
            }
            parts.append(contentsOf: important)
        }
        return parts.joined(separator: " · ")
    }

    @discardableResult

    func loadPartialResults(from outDir: URL) -> Bool {
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

    func loadModelStats() {
        guard !isLoadingModelStats else { return }
        guard let context = modelStatsRunContext() else { return }

        isLoadingModelStats = true
        modelStatsStatusText = "Loading model stats"

        DispatchQueue.global(qos: .userInitiated).async {
            self.runModelStatsLoad(context)
        }
    }

    func modelStatsRunContext() -> TestModelStatsRunContext? {
        let scriptURL = modelStatsScriptURL
        let baseEnvironment = ProcessInfo.processInfo.environment
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            modelStats = nil
            modelStatsStatusText = "Stats script not found: \(scriptURL.path)"
            return nil
        }

        var environment = baseEnvironment
        environment.removeValue(forKey: "SOMA_PROJECT_ROOT")
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PATH"] = codexSearchPath(existing: baseEnvironment["PATH"])
        return TestModelStatsRunContext(
            scriptURL: scriptURL,
            stressURL: stressDirectoryURL,
            rootURL: repoRootURL,
            environment: environment
        )
    }

    func runModelStatsLoad(_ context: TestModelStatsRunContext) {
        var output: TestModelStatsOutput?
        do {
            let preparedOutput = try prepareModelStatsOutput()
            output = preparedOutput
            let process = makeModelStatsProcess(context: context, output: preparedOutput)
            try process.run()
            process.waitUntilExit()
            preparedOutput.close()
            defer { preparedOutput.cleanup() }

            let data = (try? Data(contentsOf: preparedOutput.stdoutURL)) ?? Data()
            if process.terminationStatus != 0 {
                applyModelStatsProcessFailure(output: preparedOutput, data: data)
                return
            }
            let decoded = try JSONDecoder().decode(TestModelStatsEnvelope.self, from: data)
            applyModelStatsSuccess(decoded)
        } catch {
            output?.close()
            let stderrText = output.flatMap { try? String(contentsOf: $0.stderrURL, encoding: .utf8) } ?? ""
            output?.cleanup()
            applyModelStatsLoadError(error, stderrText: stderrText)
        }
    }

    func prepareModelStatsOutput() throws -> TestModelStatsOutput {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-model-stats-\(UUID().uuidString)", isDirectory: true)
        let stdoutURL = tempDirectory.appendingPathComponent("stdout.json")
        let stderrURL = tempDirectory.appendingPathComponent("stderr.log")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        return TestModelStatsOutput(
            tempDirectory: tempDirectory,
            stdoutURL: stdoutURL,
            stderrURL: stderrURL,
            stdoutHandle: try FileHandle(forWritingTo: stdoutURL),
            stderrHandle: try FileHandle(forWritingTo: stderrURL)
        )
    }

    func makeModelStatsProcess(context: TestModelStatsRunContext, output: TestModelStatsOutput) -> Process {
        let process = Process()
        process.currentDirectoryURL = context.rootURL
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            context.scriptURL.path,
            "--stress-dir", context.stressURL.path,
        ]
        process.environment = context.environment
        process.standardOutput = output.stdoutHandle
        process.standardError = output.stderrHandle
        return process
    }

    func applyModelStatsProcessFailure(output: TestModelStatsOutput, data: Data) {
        let stderrText = (try? String(contentsOf: output.stderrURL, encoding: .utf8)) ?? ""
        let stdoutText = String(data: data, encoding: .utf8) ?? ""
        let text = [stderrText, stdoutText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        DispatchQueue.main.async {
            self.isLoadingModelStats = false
            self.modelStatsStatusText = "Stats failed: \(text)"
        }
    }

    func applyModelStatsSuccess(_ decoded: TestModelStatsEnvelope) {
        DispatchQueue.main.async {
            self.modelStats = decoded
            self.selectedTranslationStatsID = decoded.translationModels.first?.id
            self.selectedImproverStatsID = decoded.improverModels.first?.id
            self.modelStatsStatusText =
                "Loaded \(decoded.translationModels.count) translation model(s), \(decoded.improverModels.count) improver model(s)"
            self.isLoadingModelStats = false
        }
    }

    func applyModelStatsLoadError(_ error: Error, stderrText: String) {
        DispatchQueue.main.async {
            self.modelStats = nil
            let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            self.modelStatsStatusText =
                detail.isEmpty
                ? "Could not load model stats: \(error.localizedDescription)"
                : "Could not load model stats: \(error.localizedDescription)\n\(detail)"
            self.isLoadingModelStats = false
        }
    }

    func loadModelStatsIfNeeded() {
        guard modelStats == nil, !isLoadingModelStats else { return }
        loadModelStats()
    }

    func openStressLogsFolder() {
        try? FileManager.default.createDirectory(at: stressDirectoryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(stressDirectoryURL)
    }

}

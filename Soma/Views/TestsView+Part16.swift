import SwiftUI
import AppKit
import Foundation

extension TestsView {
    func updateProgress(from event: TestProgressEvent) {
        currentProgressEvent = event
        updateProgressContext(from: event)
        setCurrentStage(displayStage(for: event))
        applyProgressEvent(event)
    }


    func updateProgressContext(from event: TestProgressEvent) {
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
    }


    func applyProgressEvent(_ event: TestProgressEvent) {
        switch event.event {
        case "run_start":
            applyRunStartProgress()
        case "stage_start":
            applyStageStartProgress(event)
        case "stage_complete":
            currentTestStatus = operationStatusText(for: event)
            updateProgressValue(for: event, extra: 0.04)
        case "translation_gate":
            applyTranslationGateProgress(event)
        case "confidence_batch_start":
            applyConfidenceBatchProgress(event, isComplete: false)
        case "confidence_batch_complete":
            applyConfidenceBatchProgress(event, isComplete: true)
        case "result_write":
            applyResultWriteProgress()
        case "run_finished":
            applyRunFinishedProgress()
        default:
            currentTestStatus = operationStatusText(for: event)
        }
    }


    func applyRunStartProgress() {
        currentTestStatus = "Run queued"
        completedCases = 0
        progressValue = 0
    }


    func applyStageStartProgress(_ event: TestProgressEvent) {
        currentTestStatus = operationStatusText(for: event)
        if event.stage == "translating" {
            translationGateState = "Pending"
        }
        updateProgressValue(for: event)
    }


    func applyTranslationGateProgress(_ event: TestProgressEvent) {
        currentTestStatus = event.status == "rejected" ? "Translation rejected; improvers skipped" : "Translation accepted"
        if event.status == "rejected" {
            translationGateState = "Rejected"
            trackRejectedTranslation(event)
        } else {
            translationGateState = "Accepted"
        }
        updateProgressValue(for: event)
    }


    func trackRejectedTranslation(_ event: TestProgressEvent) {
        let key = "\(event.caseID ?? "-")|\(event.translatorModel ?? "-")"
        if rejectedTranslationKeys.insert(key).inserted {
            rejectedTranslationCount += 1
            skippedImproverCount += selectedImproverModels.count
        }
    }


    func applyConfidenceBatchProgress(_ event: TestProgressEvent, isComplete: Bool) {
        if isComplete {
            confidenceBatchesFinished += 1
        } else {
            confidenceBatchesStarted += 1
            if event.stage.contains("translation_confidence") {
                translationGateState = "Checking"
            }
        }
        currentTestStatus = batchStatusText(for: event, verb: isComplete ? "Checked" : "Checking")
        updateProgressValue(for: event, extra: isComplete ? 0.04 : 0)
    }


    func applyResultWriteProgress() {
        currentTestStatus = "Saved result"
        completedCases = min(completedCases + 1, totalCasesToRun)
        progressValue = Double(completedCases)
    }


    func applyRunFinishedProgress() {
        currentTestStatus = "All tests finished"
        completedCases = totalCasesToRun
        progressValue = Double(totalCasesToRun)
    }


    func updateProgressValue(for event: TestProgressEvent, extra: Double = 0) {
        let base = Double(max((event.operationIndex ?? 1) - 1, 0))
        progressValue = min(base + stageFraction(event.stage) + extra, Double(max(totalCasesToRun, 1)))
    }


    func updateProgress(from line: String) {
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


    func setCurrentStage(_ stage: String) {
        guard currentStage != stage else { return }
        currentStage = stage
        currentStageStartedAt = Date()
        currentStageElapsedSeconds = 0
    }


    func displayStage(for event: TestProgressEvent) -> String {
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


    func operationStatusText(for event: TestProgressEvent) -> String {
        if let operation = event.operationIndex, let total = event.totalOperations, total > 0 {
            return "Operation \(operation)/\(total)"
        }
        return event.status?.capitalized ?? currentTestStatus
    }


    func batchStatusText(for event: TestProgressEvent, verb: String) -> String {
        let batch = {
            if let index = event.batchIndex, let total = event.batchTotal {
                return " batch \(index)/\(total)"
            }
            return " confidence batch"
        }()
        let size = event.batchSize.map { " with \($0) item(s)" } ?? ""
        return "\(verb)\(batch)\(size)"
    }


    func activityText(for event: TestProgressEvent) -> String {
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

}

import SwiftUI
import AppKit
import Foundation

extension TestsView {
    var translationGateStateText: String {
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


    var translationGateTone: SomaStatusTone {
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


    var activeImproverOrBatchText: String {
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


    var translatorFromPair: String {
        currentModelPair.components(separatedBy: " -> ").first ?? currentModelPair
    }


    var analyzerFromPair: String {
        let parts = currentModelPair.components(separatedBy: " -> ")
        guard parts.count > 1 else { return "-" }
        return parts[1]
    }


    var casesDirectoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Scripts")
            .appendingPathComponent("rus_to_prompt_tests")
    }


    var casesURL: URL {
        casesDirectoryURL.appendingPathComponent(selectedCasesFileName)
    }


    var repoRootURL: URL {
        casesDirectoryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }


    var stressScriptURL: URL {
        repoRootURL
            .appendingPathComponent("Scripts")
            .appendingPathComponent("rus_to_prompt_stress.py")
    }


    var modelStatsScriptURL: URL {
        repoRootURL
            .appendingPathComponent("Scripts")
            .appendingPathComponent("rus_to_prompt_stats.py")
    }


    var stressDirectoryURL: URL {
        repoRootURL.appendingPathComponent(".stress")
    }


    var selectedResultRow: TestModelCombinationSummary? {
        guard let selectedResultRowID else { return resultRows.first }
        return resultRows.first(where: { $0.id == selectedResultRowID }) ?? resultRows.first
    }


    var selectedRunRow: TestRunResult? {
        guard let selectedRunRowID else { return resultRunRows.first }
        return resultRunRows.first(where: { $0.id == selectedRunRowID }) ?? resultRunRows.first
    }


    var resultCaseGroups: [TestCaseRunGroup] {
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


    var canStartTests: Bool {
        caseCount > 0
            && FileManager.default.fileExists(atPath: casesURL.path)
            && FileManager.default.fileExists(atPath: stressScriptURL.path)
            && !selectedTranslatorModels.isEmpty
            && (selectedBenchmarkMode == .translation || !selectedImproverModels.isEmpty)
    }


    var transformOperationCount: Int {
        switch selectedBenchmarkMode {
        case .translation:
            return caseCount * selectedTranslatorModels.count
        case .staged:
            return caseCount * (selectedTranslatorModels.count + selectedImproverModels.count)
        case .matrix:
            return caseCount * selectedTranslatorModels.count * selectedImproverModels.count
        }
    }


    var logicalConfidenceCheckCount: Int {
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


    var estimatedConfidenceRequestCount: Int {
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


    var benchmarkEstimateText: String {
        switch selectedBenchmarkMode {
        case .translation:
            return "\(transformOperationCount) translation operations, \(logicalConfidenceCheckCount) confidence checks"
        case .staged:
            return "\(transformOperationCount) operations: \(caseCount * selectedTranslatorModels.count) translations + \(caseCount * selectedImproverModels.count) improver runs"
        case .matrix:
            return "\(transformOperationCount) full matrix operations"
        }
    }


    var runReadinessText: String {
        if isRunningTests { return "Running \(totalCasesToRun) transform operations; confidence workers x\(effectiveConfidenceWorkers)." }
        if caseCount <= 0 { return "Add at least one test case to start." }
        if selectedTranslatorModels.isEmpty { return "Choose at least one translator model." }
        if selectedBenchmarkMode != .translation && selectedImproverModels.isEmpty { return "Choose at least one improver model." }
        if hybridConfidenceActive {
            return "\(selectedBenchmarkMode.rawValue): \(transformOperationCount) operations, \(logicalConfidenceCheckCount) confidence items, two local judges first; \(providerDisplayName(selectedConfidenceFallbackReferee)) only on issues."
        }
        return "\(selectedBenchmarkMode.rawValue): \(transformOperationCount) operations, \(logicalConfidenceCheckCount) checks as ~\(estimatedConfidenceRequestCount) batched requests x\(effectiveConfidenceWorkers)."
    }


    var activeConfidenceSummary: String {
        if hybridConfidenceActive {
            return "Local x2 -> \(providerDisplayName(selectedConfidenceFallbackReferee)) \(hybridGeminiFallbackModel)"
        }
        return "\(selectedConfidenceModel) · \(selectedConfidenceProviderLabel)"
    }

}

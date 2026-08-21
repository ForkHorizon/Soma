import SwiftUI
import AppKit
import Foundation

extension TestsView {
    func formatConfidence(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.2f", value)
    }

    func formatSeconds(_ value: Double) -> String {
        if value >= 60 {
            return String(format: "%.1fm", value / 60)
        }
        return String(format: "%.1fs", value)
    }

    func formatOptionalSeconds(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return formatSeconds(value)
    }

    func formatPercent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    func shortDateTime(_ value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "-"
        }
        return String(value.prefix(19)).replacingOccurrences(of: "T", with: " ")
    }

    func confidenceTone(_ value: Double?, failed: Int = 0) -> SomaStatusTone {
        if failed > 0 { return .warning }
        guard let value else { return .neutral }
        if value >= 0.85 { return .good }
        if value >= 0.75 { return .info }
        if value >= 0.50 { return .warning }
        return .danger
    }

    func providerTone(_ provider: String) -> SomaStatusTone {
        switch provider {
        case "Codex":
            return .info
        case "Gemini":
            return .warning
        case "DeepSeek":
            return .info
        case "Local":
            return .good
        default:
            return .neutral
        }
    }

    func runStatusTone(_ status: String) -> SomaStatusTone {
        switch status {
        case "ok", "translation_ready":
            return .good
        case "degraded":
            return .warning
        default:
            return .danger
        }
    }

    func effectiveConfidence(_ confidence: TestRunConfidence?) -> Double {
        guard let confidence, !confidence.isFailed, let value = confidence.usableConfidence else { return -1 }
        return value
    }

    func runLowStageCount(_ row: TestRunResult) -> Int {
        [row.translationConfidence, row.improveConfidence, row.overallConfidence].reduce(0) { count, confidence in
            if confidence?.isFailed == true { return count + 1 }
            if let value = confidence?.usableConfidence, value < 0.75 { return count + 1 }
            return count
        }
    }

    func runConfidenceHelp(_ confidence: TestRunConfidence?) -> String {
        guard let confidence else { return "No confidence result" }
        let value = confidence.isFailed ? "failed" : (confidence.usableConfidence.map { String(format: "%.2f", $0) } ?? "n/a")
        let status = confidence.canonicalStatus
        let raw = confidence.rawOrConfidence.map { ", raw \(String(format: "%.2f", $0))" } ?? ""
        let reasoning = confidence.reasoningEffort ?? RusToPromptSettingsStore.defaultConfidenceReasoning
        let stageNote = confidence.stage == "overall" ? ", Overall is final prompt safety, not improver quality" : ""
        return "status \(status), confidence \(value)\(raw), reasoning \(reasoning)\(stageNote)"
    }

    func runConfidenceSummary(_ confidence: TestRunConfidence?) -> String {
        guard let confidence else { return "n/a" }
        if confidence.isFailed { return "failed" }
        return "\(formatConfidence(confidence.usableConfidence)) \(confidence.canonicalStatus)"
    }

    func loadCases() {
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

    func refreshCasesIfChanged() {
        let previousFiles = caseFiles.map(\.lastPathComponent)
        refreshCaseFiles()
        if caseFiles.map(\.lastPathComponent) != previousFiles {
            loadSelectedCasesFile()
        }
        let modifiedAt = casesModifiedAt()
        guard modifiedAt != lastCasesModifiedAt else { return }
        loadCases()
    }

    func casesModifiedAt() -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: casesURL.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    func countCases(in text: String) -> Int {
        let usableLines =
            text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("### ") || !trimmed.hasPrefix("#")
            }
        let markerCount =
            usableLines
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("### ") }
            .count
        if markerCount > 0 { return markerCount }
        return
            usableLines
            .joined(separator: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    func loadModelSelections() {
        selectedTranslatorModels = loadModelSelection(key: translatorModelsKey, fallback: [RusToPromptSettingsStore.defaultTranslator])
        selectedImproverModels = loadModelSelection(key: improverModelsKey, fallback: [RusToPromptSettingsStore.defaultAnalyzer])
    }

    func loadConfidenceModel() {
        let stored = UserDefaults.standard.string(forKey: confidenceModelKey) ?? RusToPromptSettingsStore.defaultConfidence
        selectedConfidenceModel =
            stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? RusToPromptSettingsStore.defaultConfidence : stored
    }

    func loadLocalConfidenceModels() {
        guard let data = UserDefaults.standard.data(forKey: localConfidenceModelsKey),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        else {
            selectedLocalConfidenceModels = ["qwen3:30b-a3b", "qwen3-coder:30b-a3b-q4_K_M"]
            return
        }
        let models =
            decoded
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        selectedLocalConfidenceModels = Array(models.prefix(2))
        if selectedLocalConfidenceModels.isEmpty {
            selectedLocalConfidenceModels = ["qwen3:30b-a3b", "qwen3-coder:30b-a3b-q4_K_M"]
        }
    }

    func loadHybridConfidence() {
        if UserDefaults.standard.object(forKey: hybridConfidenceKey) == nil {
            useHybridConfidence = true
            return
        }
        useHybridConfidence = UserDefaults.standard.bool(forKey: hybridConfidenceKey)
    }

    func loadConfidenceBatchSize() {
        let stored = UserDefaults.standard.integer(forKey: confidenceBatchSizeKey)
        selectedConfidenceBatchSize = [1, 5, 10, 20].contains(stored) ? stored : 10
    }

    func loadBenchmarkMode() {
        let stored = UserDefaults.standard.string(forKey: benchmarkModeKey)
        selectedBenchmarkMode = TestBenchmarkMode.allCases.first { $0.cliValue == stored || $0.rawValue == stored } ?? .staged
    }

    func loadModelSelection(key: String, fallback: Set<String>) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        else {
            return fallback
        }
        let selected = Set(decoded.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        return selected.isEmpty ? fallback : selected
    }

    func saveModelSelection(_ selection: Set<String>, key: String) {
        let models = Array(selection).sorted()
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func saveConfidenceModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: confidenceModelKey)
    }

}

import SwiftUI

extension RusToPromptView {
    var activeModelLabel: String {
        switch viewModel.phase {
        case .translating:
            return shortModelName(viewModel.translatorModel)
        case .analyzing:
            return shortModelName(viewModel.analyzerModel)
        case .checkingConfidence:
            return shortModelName(viewModel.confidenceModel)
        default:
            return ""
        }
    }


    var phaseIcon: String {
        switch viewModel.phase {
        case .idle: return ollama.isOllamaRunning ? "checkmark.circle" : "exclamationmark.triangle.fill"
        case .translating: return "text.bubble"
        case .analyzing: return "brain"
        case .checkingConfidence: return "gauge.with.dots.needle.50percent"
        case .done: return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }


    var phaseTone: SomaStatusTone {
        if selectedModelsNeedOllama && !ollama.isOllamaRunning && !viewModel.isBusy { return .warning }
        switch viewModel.phase {
        case .idle: return .neutral
        case .translating, .analyzing, .checkingConfidence: return .info
        case .done: return .good
        case .degraded: return .warning
        case .failed: return .danger
        }
    }


    var busyButtonTitle: String {
        switch viewModel.phase {
        case .translating: return "Translating"
        case .analyzing: return "Analyzing"
        case .checkingConfidence: return "Checking"
        default: return "Working"
        }
    }


    var confidenceOutputText: String {
        guard let result = viewModel.confidenceResult else {
            return viewModel.confidenceWarning ?? ""
        }
        var lines: [String] = []
        if let confidence = result.confidence {
            lines.append(String(format: "Confidence: %.0f%%", confidence * 100))
        }
        if let verdict = result.verdict {
            lines.append("Verdict: \(verdict)")
        }
        lines.append("Model: \(result.model ?? viewModel.confidenceModel)")
        lines.append("Reasoning: \(result.reasoningEffort ?? RusToPromptSettingsStore.defaultConfidenceReasoning)")
        if let status = result.status {
            lines.append("Status: \(status)")
        }
        if let scores = result.scores, !scores.isEmpty {
            lines.append("")
            lines.append("Scores:")
            for key in scores.keys.sorted() {
                lines.append("- \(key): \(scores[key] ?? 0)/5")
            }
        }
        let warnings = result.warnings?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        if !warnings.isEmpty {
            lines.append("")
            lines.append("Warnings:")
            lines.append(contentsOf: warnings.map { "- \($0)" })
        }
        let notes = result.notes?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        if !notes.isEmpty {
            lines.append("")
            lines.append("Notes:")
            lines.append(contentsOf: notes.map { "- \($0)" })
        }
        if let error = result.error, !error.isEmpty {
            lines.append("")
            lines.append("Error: \(error)")
        }
        return lines.joined(separator: "\n")
    }


    func isInstalled(_ model: String) -> Bool {
        ollama.installedModels.contains { $0.name.lowercased() == model.lowercased() }
    }


    func qualityTone(_ quality: String) -> SomaStatusTone {
        switch quality {
        case "Best", "High": return .good
        case "Good": return .info
        default: return .neutral
        }
    }


    func speedTone(_ speed: String) -> SomaStatusTone {
        switch speed {
        case "Fast", "Fastest": return .good
        case "Balanced", "Medium": return .info
        default: return .warning
        }
    }


    func confidenceTone(_ confidence: Double) -> SomaStatusTone {
        if confidence >= 0.90 { return .good }
        if confidence >= 0.75 { return .info }
        if confidence >= 0.50 { return .warning }
        return .danger
    }


    func shortModelName(_ model: String) -> String {
        if model.count <= 30 { return model }
        return String(model.prefix(27)) + "..."
    }
}

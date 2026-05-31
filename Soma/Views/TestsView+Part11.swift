import SwiftUI
import AppKit
import Foundation

extension TestsView {
    func resultDetailPanel(_ row: TestModelCombinationSummary) -> some View {
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


    func runDetailPanel(_ row: TestRunResult) -> some View {
        let warnings = row.warnings.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return VStack(alignment: .leading, spacing: 8) {
            runDetailHeader(row)
            runDetailMetadata(row)
            Divider()
            runStageColumns(row)
            runWarningsView(warnings)
        }
        .padding(10)
        .background(Color(NSColor.textBackgroundColor).opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.10)))
    }


    func runDetailHeader(_ row: TestRunResult) -> some View {
        HStack(spacing: 8) {
            Text("\(row.caseID) · Source -> Translation -> Improved Prompt")
                .font(.caption.bold())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            StatusChip(text: row.status, tone: runStatusTone(row.status))
            StatusChip(text: "low \(runLowStageCount(row))", tone: runLowStageCount(row) > 0 ? .warning : .good)
        }
    }


    func runDetailMetadata(_ row: TestRunResult) -> some View {
        Text([
            "Translator model: \(row.translatorModel)",
            "Improver model: \(row.analyzerModel)",
            "Runtime: \(formatSeconds(row.seconds))"
        ].joined(separator: " · "))
            .font(.caption.monospaced())
            .foregroundColor(.secondary)
            .lineLimit(1)
            .textSelection(.enabled)
    }


    func runStageColumns(_ row: TestRunResult) -> some View {
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
    }


    @ViewBuilder
    func runWarningsView(_ warnings: [String]) -> some View {
        if !warnings.isEmpty {
            Divider()
            Text(warnings.prefix(3).map { "- \($0)" }.joined(separator: "\n"))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }


    func runTextStage(title: String, subtitle: String, text: String) -> some View {
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


    func progressMetric(_ title: String, _ value: String) -> some View {
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


    func pipelineStepView(_ step: TestPipelineStep) -> some View {
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


    func pipelineConnectorColor(before step: TestPipelineStep) -> Color {
        let activeStep = activePipelineStep
        if activeStep.rawValue > step.rawValue || (!isRunningTests && currentStage == "Done") {
            return SomaStatusTone.good.color.opacity(0.65)
        }
        if activeStep == step && isRunningTests {
            return Color.accentColor.opacity(0.45)
        }
        return Color.secondary.opacity(0.18)
    }


    var activePipelineStep: TestPipelineStep {
        pipelineStep(for: currentProgressEvent?.stage ?? currentStage)
    }


    func pipelineStep(for stage: String) -> TestPipelineStep {
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


    var pipelineStatusTone: SomaStatusTone {
        let normalizedStage = currentStage.lowercased()
        let normalizedStatus = currentProgressEvent?.status?.lowercased() ?? ""
        if normalizedStage.contains("fail") || normalizedStatus == "failed" { return .danger }
        if normalizedStage.contains("reject") || normalizedStatus == "rejected" { return .warning }
        if normalizedStage == "done" || normalizedStatus == "ok" || normalizedStatus == "accepted" { return .good }
        if isRunningTests { return .info }
        return .neutral
    }


    var progressPercentText: String {
        guard totalCasesToRun > 0 else { return "0%" }
        let percent = min(max(progressValue / Double(max(totalCasesToRun, 1)), 0), 1) * 100
        return String(format: "%.0f%%", percent)
    }


    var runElapsedText: String {
        guard let runStartedAt else { return "elapsed -" }
        return "elapsed \(formatSeconds(Date().timeIntervalSince(runStartedAt)))"
    }

}

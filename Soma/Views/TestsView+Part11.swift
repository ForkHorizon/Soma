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

            let samples = resultSamples(for: row)
            if !samples.isEmpty {
                Divider()
                Text("Case samples")
                    .font(.caption.bold())
                VStack(spacing: 0) {
                    ForEach(samples) { sample in
                        Button {
                            selectedResultsMode = .byCase
                            selectedRunRowID = sample.id
                            expandedRunDebugIDs.insert(sample.id)
                        } label: {
                            HStack(spacing: 8) {
                                Text(sample.caseID)
                                    .font(.caption.monospaced().weight(.semibold))
                                    .frame(width: 86, alignment: .leading)
                                Text(runConfidenceSummary(sample.improveConfidence ?? sample.translationConfidence))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(confidenceTone((sample.improveConfidence ?? sample.translationConfidence)?.usableConfidence, failed: (sample.improveConfidence ?? sample.translationConfidence)?.isFailed == true ? 1 : 0).color)
                                    .frame(width: 78, alignment: .leading)
                                Text((sample.improvedPrompt?.isEmpty == false ? sample.improvedPrompt : sample.translation) ?? "")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
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
            Divider()
            if isRunDebugExpanded(row.id) {
                runConfidenceDebugColumns(row, judgesByItemID: resultConfidenceJudgesByItemID)
            } else {
                collapsedRunDebugHint(row)
            }
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
            Button {
                toggleRunDebug(row.id)
            } label: {
                Label(isRunDebugExpanded(row.id) ? "Hide Debug" : "Show Debug", systemImage: isRunDebugExpanded(row.id) ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
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


    func runStageColumns(_ row: TestRunResult, sourcePrompt: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            runTextStage(
                title: "1. Source",
                subtitle: row.category ?? row.caseID,
                text: sourcePrompt ?? resultPromptByCaseID[row.caseID] ?? "Source prompt not found in prompts.json."
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


    func resultSamples(for row: TestModelCombinationSummary) -> [TestRunResult] {
        Array(resultRunRows
            .filter { $0.translatorModel == row.translatorModel && $0.analyzerModel == row.analyzerModel }
            .sorted {
                let lhs = effectiveConfidence($0.overallConfidence ?? $0.improveConfidence ?? $0.translationConfidence)
                let rhs = effectiveConfidence($1.overallConfidence ?? $1.improveConfidence ?? $1.translationConfidence)
                if lhs == rhs { return $0.caseID < $1.caseID }
                return lhs < rhs
            }
            .prefix(5))
    }


    func isRunDebugExpanded(_ id: String) -> Bool {
        expandedRunDebugIDs.contains(id)
    }


    func toggleRunDebug(_ id: String) {
        if expandedRunDebugIDs.contains(id) {
            expandedRunDebugIDs.remove(id)
        } else {
            expandedRunDebugIDs.insert(id)
        }
    }


    func collapsedRunDebugHint(_ row: TestRunResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundColor(.secondary)
            Text("Debug hidden for \(row.caseID). Click the row again or use Show Debug to inspect per-judge confidence.")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
        }
    }


    func runConfidenceDebugColumns(
        _ row: TestRunResult,
        judgesByItemID: [String: [TestConfidenceJudgeResult]]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Confidence Debug")
                    .font(.caption.bold())
                StatusChip(text: "\(confidenceJudgeCount(row, judgesByItemID: judgesByItemID)) judge rows", tone: confidenceJudgeCount(row, judgesByItemID: judgesByItemID) > 0 ? .info : .neutral)
                Spacer()
                Text("Overall is final prompt safety; Improve is improver quality.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .top, spacing: 12) {
                runConfidenceDebugStage(
                    title: "Translation",
                    stage: "translation",
                    finalConfidence: row.translationConfidence,
                    row: row,
                    judgesByItemID: judgesByItemID
                )
                runConfidenceDebugStage(
                    title: "Improve",
                    stage: "improve",
                    finalConfidence: row.improveConfidence,
                    row: row,
                    judgesByItemID: judgesByItemID
                )
                runConfidenceDebugStage(
                    title: "Overall",
                    stage: "overall",
                    finalConfidence: row.overallConfidence,
                    row: row,
                    judgesByItemID: judgesByItemID
                )
            }
        }
    }


    func runConfidenceDebugStage(
        title: String,
        stage: String,
        finalConfidence: TestRunConfidence?,
        row: TestRunResult,
        judgesByItemID: [String: [TestConfidenceJudgeResult]]
    ) -> some View {
        let judges = confidenceJudges(for: row, stage: stage, confidence: finalConfidence, judgesByItemID: judgesByItemID)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.bold())
                Spacer()
                StatusChip(
                    text: runConfidenceSummary(finalConfidence),
                    tone: confidenceTone(finalConfidence?.usableConfidence, failed: finalConfidence?.isFailed == true ? 1 : 0)
                )
            }

            Text(confidenceMetaText(finalConfidence, fallbackStage: stage))
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            if judges.isEmpty {
                Text("No per-judge state saved for this stage.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 5) {
                    ForEach(judges) { judge in
                        confidenceJudgeRow(judge)
                    }
                }
            }

            let notes = confidenceDetailLines(finalConfidence)
            if !notes.isEmpty {
                Text(notes.joined(separator: "\n"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(8)
        .background(Color(NSColor.textBackgroundColor).opacity(0.30))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.10)))
    }


    func confidenceJudgeRow(_ judge: TestConfidenceJudgeResult) -> some View {
        let payload = judge.payload
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(shortModelName(judge.judgeModel))
                    .font(.caption2.monospaced().weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                StatusChip(
                    text: judgeConfidenceText(payload),
                    tone: confidenceTone(payload.usableConfidence, failed: payload.isFailed ? 1 : 0)
                )
            }
            Text(judgeMetaText(payload))
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            let details = judgeDetailLines(payload)
            if !details.isEmpty {
                Text(details.joined(separator: "\n"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }


    func confidenceJudges(
        for row: TestRunResult,
        stage: String,
        confidence: TestRunConfidence?,
        judgesByItemID: [String: [TestConfidenceJudgeResult]]
    ) -> [TestConfidenceJudgeResult] {
        for itemID in confidenceItemIDs(for: row, stage: stage, confidence: confidence) {
            if let judges = judgesByItemID[itemID], !judges.isEmpty {
                return judges
            }
        }
        return (confidence?.localJudges ?? []).enumerated().map { index, payload in
            let model = payload.model ?? "local judge \(index + 1)"
            return TestConfidenceJudgeResult(
                itemID: confidence?.batchItemID ?? confidenceItemIDs(for: row, stage: stage, confidence: confidence).first ?? row.id,
                judgeModel: model,
                payload: payload
            )
        }
    }


    func confidenceItemIDs(for row: TestRunResult, stage: String, confidence: TestRunConfidence?) -> [String] {
        var ids: [String] = []
        if let batchItemID = confidence?.batchItemID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !batchItemID.isEmpty {
            ids.append(batchItemID)
        }
        ids.append([row.caseID, row.translatorModel, row.analyzerModel, stage].joined(separator: "|"))
        if stage == "translation" && row.analyzerModel != "translation-only" {
            ids.append([row.caseID, row.translatorModel, "translation-only", stage].joined(separator: "|"))
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }


    func confidenceJudgeCount(_ row: TestRunResult, judgesByItemID: [String: [TestConfidenceJudgeResult]]) -> Int {
        [
            ("translation", row.translationConfidence),
            ("improve", row.improveConfidence),
            ("overall", row.overallConfidence)
        ].reduce(0) { count, item in
            count + confidenceJudges(for: row, stage: item.0, confidence: item.1, judgesByItemID: judgesByItemID).count
        }
    }


    func confidenceMetaText(_ confidence: TestRunConfidence?, fallbackStage: String) -> String {
        guard let confidence else { return "No final confidence payload for \(fallbackStage)." }
        var parts = [
            confidence.stage ?? fallbackStage,
            confidence.provider ?? "unknown provider",
            confidence.model ?? "unknown model",
            confidence.canonicalStatus
        ]
        if let rawStatus = confidence.rawStatus, rawStatus != confidence.canonicalStatus {
            parts.append("raw \(rawStatus)")
        }
        if let rawConfidence = confidence.rawOrConfidence, rawConfidence != confidence.usableConfidence {
            parts.append("raw score \(String(format: "%.2f", rawConfidence))")
        }
        if let seconds = confidence.seconds {
            parts.append(formatSeconds(seconds))
        }
        if confidence.hybridEscalated == true {
            parts.append("fallback \(confidence.fallbackProvider ?? "") \(confidence.fallbackModel ?? "")".trimmingCharacters(in: .whitespaces))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }


    func confidenceDetailLines(_ confidence: TestRunConfidence?) -> [String] {
        guard let confidence else { return [] }
        var lines: [String] = []
        if let reason = confidence.hybridEscalationReason, !reason.isEmpty {
            lines.append("Escalation: \(reason)")
        }
        lines.append(contentsOf: (confidence.deterministicCapReasons ?? []).map { "Cap: \($0)" })
        lines.append(contentsOf: (confidence.warnings ?? []).map { "Warning: \($0)" })
        lines.append(contentsOf: (confidence.notes ?? []).map { "Note: \($0)" })
        if let error = confidence.error, !error.isEmpty {
            lines.append("Error: \(error)")
        }
        return Array(lines.prefix(6))
    }


    func judgeConfidenceText(_ payload: TestConfidenceJudgePayload) -> String {
        if payload.isFailed { return "failed" }
        return formatConfidence(payload.usableConfidence)
    }


    func judgeMetaText(_ payload: TestConfidenceJudgePayload) -> String {
        var parts = [
            payload.provider ?? "local",
            payload.stage ?? "stage",
            payload.canonicalStatus,
            payload.verdict ?? ""
        ]
        if let rawStatus = payload.rawStatus, rawStatus != payload.canonicalStatus {
            parts.append("raw \(rawStatus)")
        }
        if let rawConfidence = payload.rawOrConfidence, rawConfidence != payload.usableConfidence {
            parts.append("raw score \(String(format: "%.2f", rawConfidence))")
        }
        if let seconds = payload.seconds {
            parts.append(formatSeconds(seconds))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }


    func judgeDetailLines(_ payload: TestConfidenceJudgePayload) -> [String] {
        var lines: [String] = []
        lines.append(contentsOf: (payload.deterministicCapReasons ?? []).map { "Cap: \($0)" })
        lines.append(contentsOf: (payload.warnings ?? []).map { "Warning: \($0)" })
        lines.append(contentsOf: (payload.notes ?? []).map { "Note: \($0)" })
        if let error = payload.error, !error.isEmpty {
            lines.append("Error: \(error)")
        }
        return Array(lines.prefix(5))
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

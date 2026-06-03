import SwiftUI
import AppKit
import Foundation

struct QueueModelProgressRow: Identifiable {
    let id: String
    let role: String
    let model: String
    let progress: String
    let status: String
    let detail: String
    let confidence: TestRunConfidence?
    let tone: SomaStatusTone
    let result: TestRunResult?
}
extension TestsView {
    func queueItemHeader(_ item: RusToPromptQueueItem) -> some View {
        HStack(spacing: 8) {
            queueDisclosureButton(item)
            StatusChip(text: queueItemStatusText(item), tone: queueItemTone(item))
            Text(item.id)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer()
            queueOutputButton(item)
            Button {
                queueManager.retry(item)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(item.status == .running)
            .help("Retry")
            Button {
                queueManager.remove(item)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help("Remove")
        }
    }
    func queueDisclosureButton(_ item: RusToPromptQueueItem) -> some View {
        Button {
            toggleQueueItemExpanded(item.id)
        } label: {
            Image(systemName: isQueueItemExpanded(item.id) ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(isQueueItemExpanded(item.id) ? "Hide model status" : "Show model status")
    }
    @ViewBuilder
    func queueOutputButton(_ item: RusToPromptQueueItem) -> some View {
        if let output = item.outputPath {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: output))
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help(output)
        }
    }
    func isQueueItemExpanded(_ id: String) -> Bool {
        expandedQueueItemIDs.contains(id)
    }
    func toggleQueueItemExpanded(_ id: String) {
        if expandedQueueItemIDs.contains(id) {
            expandedQueueItemIDs.remove(id)
        } else {
            expandedQueueItemIDs.insert(id)
        }
    }

    @ViewBuilder
    func queueItemDetails(_ item: RusToPromptQueueItem) -> some View {
        let rows = queueModelProgressRows(for: item)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Model status")
                    .font(.caption.weight(.semibold))
                Spacer()
                let running = rows.filter { $0.status == "running" }.count
                if running > 0 {
                    StatusChip(text: "\(running) running", tone: .info)
                }
                StatusChip(
                    text: "\(rows.filter { $0.status == "completed" }.count)/\(rows.count) complete",
                    tone: rows.isEmpty ? .neutral : .info
                )
            }

            if rows.isEmpty {
                Text("No model snapshot yet.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(rows) { row in
                            queueModelProgressBlock(row, item: item)
                        }
                    }
                }
                .frame(maxHeight: rows.count > 8 ? 320 : nil)
            }
        }
        .padding(.top, 4)
    }

    var queueDetailsHeader: some View {
        HStack(spacing: 8) {
            Text("Role")
                .frame(width: 76, alignment: .leading)
            Text("Model")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Progress")
                .frame(width: 128, alignment: .leading)
            Text("Status")
                .frame(width: 96, alignment: .leading)
            Text("Conf")
                .frame(width: 48, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundColor(.secondary)
    }

    func queueModelProgressBlock(_ row: QueueModelProgressRow, item: RusToPromptQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            queueModelProgressRow(row, item: item)
            if queueModelDebugIsExpanded(row, item: item), let result = row.result {
                queueRunDebugPanel(result, item: item)
            }
        }
    }

    func queueModelProgressRow(_ row: QueueModelProgressRow, item: RusToPromptQueueItem) -> some View {
        Button {
            guard row.result != nil else { return }
            toggleQueueModelDebug(row, item: item)
        } label: {
            HStack(spacing: 8) {
                queueRoleIcon(row.role)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortModelName(row.model))
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(row.progress)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)
                Spacer(minLength: 6)
                if row.result != nil {
                    Image(systemName: queueModelDebugIsExpanded(row, item: item) ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                VStack(alignment: .trailing, spacing: 2) {
                    StatusChip(text: row.status, tone: row.tone)
                    Text(queueConfidenceText(row.confidence, status: row.status))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(confidenceTone(row.confidence?.usableConfidence, failed: row.confidence?.isFailed == true ? 1 : 0).color)
                        .lineLimit(1)
                }
                .frame(width: 92, alignment: .trailing)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor).opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(row.result == nil ? row.detail : "\(row.detail). Click to inspect input, output, and confidence judges.")
    }

    func queueRoleIcon(_ role: String) -> some View {
        let isTranslate = role == "Translate"
        return Image(systemName: isTranslate ? "character.bubble" : "wand.and.sparkles")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(isTranslate ? SomaStatusTone.info.color : SomaStatusTone.good.color)
            .frame(width: 22, height: 22)
            .background((isTranslate ? SomaStatusTone.info.color : SomaStatusTone.good.color).opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .help(role)
    }

    func queueModelProgressRows(for item: RusToPromptQueueItem) -> [QueueModelProgressRow] {
        let snapshot = item.snapshot ?? displaySnapshotFromSettings()
        let results = queueRunResults(for: item)
        var rows: [QueueModelProgressRow] = []
        for model in snapshot.translatorModels {
            rows.append(queueTranslatorRow(model: model, item: item, results: results, snapshot: snapshot))
        }
        for model in snapshot.improverModels {
            rows.append(queueImproverRow(model: model, item: item, results: results, snapshot: snapshot))
        }
        return rows
    }

    func queueTranslatorRow(
        model: String,
        item: RusToPromptQueueItem,
        results: [TestRunResult],
        snapshot: RusToPromptQueueItemSnapshot
    ) -> QueueModelProgressRow {
        let result = results.last {
            $0.translatorModel == model && $0.analyzerModel == "translation-only"
        }
        if let state = queueManager.queueModelProgress(itemID: item.id, role: "Translate", model: model),
           state.status != "completed" || result == nil {
            return progressQueueRow(role: "Translate", model: model, state: state, confidence: result?.translationConfidence)
        }
        if let result {
            return completedQueueRow(role: "Translate", model: model, result: result, confidence: result.translationConfidence, snapshot: snapshot)
        }
        return pendingQueueRow(role: "Translate", model: model, item: item, snapshot: snapshot)
    }

    func queueImproverRow(
        model: String,
        item: RusToPromptQueueItem,
        results: [TestRunResult],
        snapshot: RusToPromptQueueItemSnapshot
    ) -> QueueModelProgressRow {
        let result = results.last {
            $0.analyzerModel == model && $0.analyzerModel != "translation-only"
        }
        if let state = queueManager.queueModelProgress(itemID: item.id, role: "Improve", model: model),
           state.status != "completed" || result == nil {
            return progressQueueRow(role: "Improve", model: model, state: state, confidence: result?.improveConfidence ?? result?.overallConfidence)
        }
        if let result {
            return completedQueueRow(
                role: "Improve",
                model: model,
                result: result,
                confidence: result.improveConfidence ?? result.overallConfidence,
                snapshot: snapshot
            )
        }
        return pendingQueueRow(role: "Improve", model: model, item: item, snapshot: snapshot)
    }

    func completedQueueRow(
        role: String,
        model: String,
        result: TestRunResult,
        confidence: TestRunConfidence?,
        snapshot: RusToPromptQueueItemSnapshot
    ) -> QueueModelProgressRow {
        let failed = result.status == "failed" || result.status == "exception"
        let rejected = result.status == "translation_rejected"
        let status = failed ? "failed" : rejected ? "rejected" : "completed"
        let tone: SomaStatusTone = failed || rejected ? .warning : .good
        let confidenceDetail = queueConfidenceDetail(confidence, snapshot: snapshot)
        let stageDetail = queueConfidenceStageDetail(role: role, result: result, selected: confidence)
        return QueueModelProgressRow(
            id: "\(role)|\(model)",
            role: role,
            model: model,
            progress: "\(queueStageTotal(role: role, snapshot: snapshot))/\(queueStageTotal(role: role, snapshot: snapshot)) · Saved",
            status: status,
            detail: "\(result.comboID) · \(result.status) · \(confidenceDetail)\(stageDetail)",
            confidence: confidence,
            tone: tone,
            result: result
        )
    }

    func progressQueueRow(
        role: String,
        model: String,
        state: QueueModelProgressState,
        confidence: TestRunConfidence?
    ) -> QueueModelProgressRow {
        QueueModelProgressRow(
            id: "\(role)|\(model)",
            role: role,
            model: model,
            progress: state.label,
            status: state.status,
            detail: state.detail,
            confidence: confidence,
            tone: queueProgressTone(state.status),
            result: nil
        )
    }

    func activeQueueRow(role: String, model: String) -> QueueModelProgressRow {
        QueueModelProgressRow(
            id: "\(role)|\(model)",
            role: role,
            model: model,
            progress: queueManager.currentStage,
            status: "running",
            detail: "\(queueManager.currentStage) · \(queueManager.currentModel)",
            confidence: nil,
            tone: .info,
            result: nil
        )
    }

    func pendingQueueRow(role: String, model: String, item: RusToPromptQueueItem, snapshot: RusToPromptQueueItemSnapshot) -> QueueModelProgressRow {
        let terminal = [.completed, .failed, .blocked, .interrupted].contains(item.status)
        let status = terminal ? "not run" : "queued"
        let detail = terminal ? "No result was written for this model." : "Still waiting in the queue."
        let total = queueStageTotal(role: role, snapshot: snapshot)
        return QueueModelProgressRow(
            id: "\(role)|\(model)",
            role: role,
            model: model,
            progress: terminal ? "-" : "0/\(total) · Queued",
            status: status,
            detail: detail,
            confidence: nil,
            tone: terminal ? .warning : .neutral,
            result: nil
        )
    }

    func queueModelDebugKey(_ row: QueueModelProgressRow, item: RusToPromptQueueItem) -> String {
        "\(item.id)|\(row.id)"
    }

    func queueModelDebugIsExpanded(_ row: QueueModelProgressRow, item: RusToPromptQueueItem) -> Bool {
        expandedQueueModelDebugIDs.contains(queueModelDebugKey(row, item: item))
    }

    func toggleQueueModelDebug(_ row: QueueModelProgressRow, item: RusToPromptQueueItem) {
        let key = queueModelDebugKey(row, item: item)
        if expandedQueueModelDebugIDs.contains(key) {
            expandedQueueModelDebugIDs.remove(key)
        } else {
            expandedQueueModelDebugIDs.insert(key)
        }
    }

    func queueRunDebugPanel(_ result: TestRunResult, item: RusToPromptQueueItem) -> some View {
        let source = queuePromptByCaseID(for: item)[result.caseID] ?? item.prompt
        let judges = queueConfidenceJudgesByItemID(for: item)
        return VStack(alignment: .leading, spacing: 8) {
            runDetailMetadata(result)
            runStageColumns(result, sourcePrompt: source)
            Divider()
            runConfidenceDebugColumns(result, judgesByItemID: judges)
        }
        .padding(8)
        .background(Color(NSColor.textBackgroundColor).opacity(0.24))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.10)))
    }

    func queuePromptByCaseID(for item: RusToPromptQueueItem) -> [String: String] {
        guard let outputPath = item.outputPath else { return [:] }
        return loadPromptManifest(from: URL(fileURLWithPath: outputPath))
    }

    func queueConfidenceJudgesByItemID(for item: RusToPromptQueueItem) -> [String: [TestConfidenceJudgeResult]] {
        guard let outputPath = item.outputPath else { return [:] }
        return loadConfidenceJudgesMap(from: URL(fileURLWithPath: outputPath))
    }

    func queueRunResults(for item: RusToPromptQueueItem) -> [TestRunResult] {
        guard let outputPath = item.outputPath else { return [] }
        let resultsURL = URL(fileURLWithPath: outputPath).appendingPathComponent("results.jsonl")
        guard let text = try? String(contentsOf: resultsURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        let decoded: [TestRunResult] = text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(TestRunResult.self, from: data)
        }
        var order: [String] = []
        var byID: [String: TestRunResult] = [:]
        for row in decoded {
            if byID[row.id] == nil {
                order.append(row.id)
            }
            byID[row.id] = row
        }
        return order.compactMap { byID[$0] }
    }

    func displaySnapshotFromSettings() -> RusToPromptQueueItemSnapshot {
        RusToPromptQueueItemSnapshot(
            translatorModels: queueManager.settings.translatorCandidates,
            improverModels: queueManager.settings.improverCandidates,
            confidenceReferee: queueManager.settings.confidenceReferee,
            confidenceModel: queueManager.settings.confidenceModel,
            localConfidenceModels: queueManager.settings.localConfidenceModels,
            hybridGeminiModel: queueManager.settings.hybridGeminiModel,
            hybridFallbackReferee: queueManager.settings.hybridFallbackReferee,
            confidenceBatchSize: queueManager.settings.confidenceBatchSize,
            cooldownSeconds: queueManager.settings.cooldownSeconds
        )
    }

    func queueRowIsActive(item: RusToPromptQueueItem, role: String, model: String) -> Bool {
        guard queueManager.activeItemID == item.id else { return false }
        if role == "Translate" {
            return queueManager.currentModel == model
                || queueManager.currentModel.hasPrefix("\(model) ->")
        }
        return queueManager.currentModel.hasSuffix("-> \(model)")
            || queueManager.currentModel == model
    }

    func queueConfidenceText(_ confidence: TestRunConfidence?, status: String) -> String {
        guard let confidence else { return status == "completed" ? "n/a" : "-" }
        if confidence.isFailed { return "failed" }
        guard let value = confidence.usableConfidence else { return status == "completed" ? "n/a" : "-" }
        return String(format: "%.2f", value)
    }

    func queueProgressTone(_ status: String) -> SomaStatusTone {
        switch status {
        case "completed", "done":
            return .good
        case "failed", "rejected", "interrupted":
            return .warning
        case "running", "cooldown":
            return .info
        default:
            return .neutral
        }
    }

    func queueStageTotal(role: String, snapshot: RusToPromptQueueItemSnapshot) -> Int {
        if snapshot.confidenceReferee == "off" {
            return 2
        }
        let judgeTotal = max(1, min(2, snapshot.localConfidenceModels.count))
        if snapshot.confidenceReferee == "hybrid" {
            return role == "Translate" ? 3 + judgeTotal : 2 + (2 * judgeTotal)
        }
        return 4
    }

    func queueConfidenceDetail(_ confidence: TestRunConfidence?, snapshot: RusToPromptQueueItemSnapshot) -> String {
        guard let confidence else {
            return snapshot.confidenceReferee == "off" ? "confidence disabled" : "confidence pending"
        }
        let value = confidence.isFailed ? "failed" : (confidence.usableConfidence.map { String(format: "%.2f", $0) } ?? "n/a")
        let raw = confidence.rawOrConfidence.map { " raw \(String(format: "%.2f", $0))" } ?? ""
        let model = confidence.model ?? snapshot.confidenceModel
        let provider = confidence.provider ?? snapshot.confidenceReferee
        return "confidence \(value)\(raw), \(provider) \(model)"
    }

    func queueConfidenceStageDetail(
        role: String,
        result: TestRunResult,
        selected: TestRunConfidence?
    ) -> String {
        if role == "Improve" {
            let improveValue = result.improveConfidence?.confidence.map { String(format: "%.2f", $0) } ?? "n/a"
            let overallValue = result.overallConfidence?.confidence.map { String(format: "%.2f", $0) } ?? "n/a"
            return " · Improve judges improver quality \(improveValue); Overall is final prompt safety \(overallValue)"
        }
        if selected?.stage == "overall" {
            return " · Overall is final prompt safety, not improver quality"
        }
        return ""
    }
}

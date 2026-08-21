import Combine
import Foundation

extension RusToPromptQueueManager {
    func modelProgressKey(itemID: String, role: String, model: String) -> String {
        "\(itemID)|\(role)|\(model)"
    }

    func resetModelProgress(itemID: String, snapshot: RusToPromptQueueItemSnapshot) {
        let prefix = "\(itemID)|"
        modelProgress = modelProgress.filter { !$0.key.hasPrefix(prefix) }
        let now = Date()
        for model in snapshot.translatorModels {
            let key = modelProgressKey(itemID: itemID, role: "Translate", model: model)
            let total = stageTotal(for: "Translate", snapshot: snapshot)
            modelProgress[key] = QueueModelProgressState(
                itemID: itemID,
                role: "Translate",
                model: model,
                label: "0/\(total) · Queued",
                detail: "Waiting for translation.",
                status: "queued",
                updatedAt: now
            )
        }
        for model in snapshot.improverModels {
            let key = modelProgressKey(itemID: itemID, role: "Improve", model: model)
            let total = stageTotal(for: "Improve", snapshot: snapshot)
            modelProgress[key] = QueueModelProgressState(
                itemID: itemID,
                role: "Improve",
                model: model,
                label: "0/\(total) · Queued",
                detail: "Waiting for selected translation.",
                status: "queued",
                updatedAt: now
            )
        }
    }

    func queueModelProgress(itemID: String, role: String, model: String) -> QueueModelProgressState? {
        modelProgress[modelProgressKey(itemID: itemID, role: role, model: model)]
    }

    func updateModelProgress(for event: QueueProgressEvent) {
        guard let itemID = activeItemID else { return }
        let targets = progressTargets(for: event)
        guard !targets.isEmpty else { return }
        let status = progressStatus(for: event)
        let detail = progressDetail(for: event)
        let now = Date()
        for target in targets {
            let key = modelProgressKey(itemID: itemID, role: target.role, model: target.model)
            let current = modelProgress[key]
            let label = progressLabel(for: event, role: target.role)
            modelProgress[key] = QueueModelProgressState(
                itemID: itemID,
                role: target.role,
                model: target.model,
                label: label,
                detail: detail,
                status: status,
                updatedAt: now
            )
            if current == nil {
                appendActivity("Tracking \(target.role.lowercased()) model \(target.model).")
            }
        }
    }

    func completeModelProgress(itemID: String) {
        let prefix = "\(itemID)|"
        let now = Date()
        for key in modelProgress.keys where key.hasPrefix(prefix) {
            guard var state = modelProgress[key], state.status == "running" else { continue }
            state.label = "Finished"
            state.detail = "Run finished before a more specific row update arrived."
            state.status = "completed"
            state.updatedAt = now
            modelProgress[key] = state
        }
    }

    func markModelProgressTerminal(itemID: String, label: String, status: String) {
        let prefix = "\(itemID)|"
        let now = Date()
        for key in modelProgress.keys where key.hasPrefix(prefix) {
            guard var state = modelProgress[key], state.status != "completed" else { continue }
            state.label = label
            state.detail = label
            state.status = status
            state.updatedAt = now
            modelProgress[key] = state
        }
    }

    func progressTargets(for event: QueueProgressEvent) -> [(role: String, model: String)] {
        if let refs = event.confidenceModelRefs, !refs.isEmpty {
            return refs.flatMap { progressTargets(stage: event.stage, translator: $0.translatorModel, analyzer: $0.analyzerModel) }
        }
        return progressTargets(stage: event.stage, translator: event.translatorModel, analyzer: event.analyzerModel)
    }

    func progressTargets(stage: String?, translator: String?, analyzer: String?) -> [(role: String, model: String)] {
        let normalizedStage = stage ?? ""
        if normalizedStage == "analyzing"
            || normalizedStage == "improve_confidence_batch"
            || normalizedStage == "overall_confidence_batch"
            || normalizedStage == "cooldown"
            || normalizedStage == "improver_resume"
        {
            if let analyzer, analyzer != "translation-only" {
                return [("Improve", analyzer)]
            }
        }
        if normalizedStage == "writing_result" {
            if let analyzer, analyzer != "translation-only" {
                return [("Improve", analyzer)]
            }
            if let translator {
                return [("Translate", translator)]
            }
        }
        if normalizedStage == "translating"
            || normalizedStage == "translation_confidence"
            || normalizedStage == "translation_confidence_batch"
            || normalizedStage == "translation_selection"
            || normalizedStage == "translation_rejected"
            || normalizedStage == "translation_resume"
            || analyzer == "translation-only"
        {
            if let translator {
                return [("Translate", translator)]
            }
        }
        if let analyzer, analyzer != "translation-only" {
            return [("Improve", analyzer)]
        }
        if let translator {
            return [("Translate", translator)]
        }
        return []
    }

    func activityText(for event: QueueProgressEvent) -> String {
        let caseID = event.caseID ?? "case"
        switch event.event {
        case "stage_start":
            return "\(caseID) \(displayStage(for: event)) started · \(currentModel)"
        case "stage_complete":
            return "\(caseID) \(displayStage(for: event)) finished · \(event.status ?? "unknown")"
        case "translation_gate":
            return "\(caseID) translation \(event.status ?? "checked") · \(event.reason ?? "")"
        case "best_translation_selected":
            let confidence = event.confidence.map { String(format: " · conf %.2f", $0) } ?? ""
            return "\(caseID) selected \(event.translatorModel ?? "no translation")\(confidence)"
        case "cooldown_start":
            return "\(caseID) cooldown started · \(event.reason ?? "")"
        case "cooldown_pause":
            return "\(caseID) cooldown paused"
        case "cooldown_complete":
            return "\(caseID) cooldown finished"
        case "result_write":
            return "\(caseID) result saved"
        case "resume_skip":
            return "\(caseID) resumed; skipped completed \(event.translatorModel ?? "") \(event.analyzerModel ?? "")"
        default:
            return "\(caseID) \(displayStage(for: event)) · \(event.status ?? "")"
        }
    }

    func displayStage(for event: QueueProgressEvent) -> String {
        switch event.stage {
        case "queued": return "Queued"
        case "translating": return "Translating"
        case "translation_confidence", "translation_confidence_batch": return "Translation Check"
        case "translation_selection": return "Selecting Translation"
        case "translation_rejected": return "Translation Rejected"
        case "analyzing": return "Improving"
        case "improve_confidence_batch": return "Improve Confidence"
        case "overall_confidence_batch": return "Overall Confidence"
        case "cooldown": return "Cooldown"
        case "writing_result": return "Saving"
        case "matrix_resume", "translation_resume", "improver_resume": return "Resuming"
        case "done": return "Done"
        case "failed": return "Failed"
        default:
            return (event.stage ?? "Working").replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    func mark(index: Int, status: RusToPromptQueueItemStatus, message: String) {
        guard items.indices.contains(index) else { return }
        items[index].status = status
        items[index].statusMessage = message
        items[index].updatedAt = Date()
        if status == .failed || status == .blocked || status == .interrupted || status == .completed {
            items[index].finishedAt = Date()
        }
        saveToDisk()
    }
}

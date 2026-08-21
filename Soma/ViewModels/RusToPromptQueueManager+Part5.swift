import Combine
import Foundation

extension RusToPromptQueueManager {
    func progressLabel(for event: QueueProgressEvent, role: String) -> String {
        let title: String
        switch event.event {
        case "stage_start":
            title = event.stage == "analyzing" ? "Improving" : displayStage(for: event)
        case "stage_complete":
            title = event.stage == "analyzing" ? "Improved" : completedStageLabel(for: event)
        case "confidence_batch_start", "confidence_batch_complete":
            if let index = event.confidenceJudgeIndex, let total = event.confidenceJudgeTotal, total > 0 {
                title = "Local judge \(index)/\(total)"
                break
            }
            if event.confidenceModel == "hybrid" {
                title = "Aggregated"
                break
            }
            title = displayStage(for: event)
        case "translation_gate":
            title = event.status == "accepted" ? "Gate accepted" : "Gate review"
        case "best_translation_selected":
            title = "Selected"
        case "result_write":
            title = event.status == "translation_only" ? "Checkpoint" : "Saved"
        case "result_update":
            title = "Saved"
        case "resume_skip":
            title = "Resumed"
        case "cooldown_start", "cooldown_pause", "cooldown_complete":
            title = "Cooldown"
        default:
            title = displayStage(for: event)
        }
        if let step = progressStep(for: event, role: role) {
            return "\(step.index)/\(step.total) · \(title)"
        }
        return title
    }

    func completedStageLabel(for event: QueueProgressEvent) -> String {
        switch event.stage {
        case "translating": return "Translated"
        case "translation_confidence", "translation_confidence_batch": return "Checked"
        default: return displayStage(for: event)
        }
    }

    func progressStatus(for event: QueueProgressEvent) -> String {
        if event.status == "failed" || event.stage == "failed" {
            return "failed"
        }
        if event.status == "rejected" || event.stage == "translation_rejected" {
            return "rejected"
        }
        if event.event == "cooldown_start" || event.event == "cooldown_pause" {
            return "cooldown"
        }
        if event.event == "cooldown_complete" {
            return "waiting"
        }
        if event.event == "stage_complete" || event.event == "confidence_batch_complete" {
            return "done"
        }
        if event.event == "confidence_batch_start", event.status == "cached" {
            return "done"
        }
        if event.event == "result_update" {
            return "completed"
        }
        if event.event == "result_write", event.status == "translation_only" {
            return activeSnapshot()?.confidenceReferee == "off" ? "completed" : "waiting"
        }
        if event.event == "result_write" {
            return "completed"
        }
        if event.event == "resume_skip" {
            return "completed"
        }
        if event.event == "translation_gate", event.status == "accepted" {
            return "done"
        }
        if event.event == "best_translation_selected" {
            return "done"
        }
        return "running"
    }

    func progressStep(for event: QueueProgressEvent, role: String) -> (index: Int, total: Int)? {
        let total = stageTotal(for: role, snapshot: activeSnapshot(), event: event)
        guard total > 0 else { return nil }
        let stage = event.stage ?? ""
        if role == "Translate" {
            if stage == "translating" || event.event?.hasPrefix("cooldown_") == true {
                return (1, total)
            }
            if stage == "translation_confidence_batch" {
                if let judge = event.confidenceJudgeIndex, event.confidenceJudgeTotal != nil {
                    return (min(total, 1 + judge), total)
                }
                return (min(total, 2), total)
            }
            if stage == "translation_confidence" {
                return (max(1, total - 1), total)
            }
            if stage == "writing_result" {
                return (event.event == "result_write" && event.status == "translation_only" ? 1 : total, total)
            }
            if stage == "translation_selection" {
                return (total, total)
            }
        } else {
            if stage == "analyzing" || event.event?.hasPrefix("cooldown_") == true {
                return (1, total)
            }
            if stage == "improve_confidence_batch" {
                if let judge = event.confidenceJudgeIndex, event.confidenceJudgeTotal != nil {
                    return (min(total, 1 + judge), total)
                }
                return (min(total, 2), total)
            }
            if stage == "overall_confidence_batch" {
                if let judge = event.confidenceJudgeIndex, let judgeTotal = event.confidenceJudgeTotal {
                    return (min(total, 1 + judgeTotal + judge), total)
                }
                return (min(total, 3), total)
            }
            if stage == "writing_result" {
                return (total, total)
            }
        }
        return nil
    }

    func stageTotal(for role: String, snapshot: RusToPromptQueueItemSnapshot?, event: QueueProgressEvent? = nil) -> Int {
        let referee = snapshot?.confidenceReferee ?? settings.confidenceReferee
        if referee == "off" {
            return 2
        }
        let eventJudgeTotal = event?.confidenceJudgeTotal
        let snapshotJudgeTotal = snapshot?.localConfidenceModels.count ?? settings.localConfidenceModels.count
        let judgeTotal = max(1, min(2, eventJudgeTotal ?? snapshotJudgeTotal))
        if referee == "hybrid" {
            return role == "Translate" ? 3 + judgeTotal : 2 + (2 * judgeTotal)
        }
        return 4
    }

    func activeSnapshot() -> RusToPromptQueueItemSnapshot? {
        guard let activeItemID else { return nil }
        return items.first(where: { $0.id == activeItemID })?.snapshot
    }

    func progressDetail(for event: QueueProgressEvent) -> String {
        var parts = [displayStage(for: event)]
        if let confidenceModel = event.confidenceModel {
            parts.append(confidenceModel)
        }
        if let index = event.confidenceJudgeIndex, let total = event.confidenceJudgeTotal {
            parts.append("judge \(index) of \(total)")
        }
        if let batchIndex = event.batchIndex, let batchTotal = event.batchTotal {
            parts.append("batch \(batchIndex) of \(batchTotal)")
        }
        if let confidence = event.confidence {
            parts.append(String(format: "confidence %.2f", confidence))
        }
        if let status = event.status {
            parts.append(status)
        }
        if let reason = event.reason, !reason.isEmpty {
            parts.append(reason)
        }
        return parts.joined(separator: " · ")
    }
}

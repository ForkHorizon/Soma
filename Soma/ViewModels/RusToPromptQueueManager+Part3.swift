import Combine
import Foundation
extension RusToPromptQueueManager {
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
            || normalizedStage == "improver_resume" {
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
            || analyzer == "translation-only" {
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
    func loadFromDisk() {
        do {
            try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: queueFileURL.path) else { return }
            let data = try Data(contentsOf: queueFileURL)
            let decoded = try JSONDecoder().decode(RusToPromptQueueDiskState.self, from: data)
            settings = decoded.settings
            items = decoded.items
            isPaused = decoded.isPaused ?? false
            isPowerPaused = decoded.isPowerPaused ?? false
            if isPowerPaused {
                isPaused = true
            }
        } catch {
            appendActivity("Queue state could not be loaded: \(error.localizedDescription)")
        }
    }
    func saveToDisk() {
        let state = RusToPromptQueueDiskState(settings: settings, items: items, isPaused: isPaused, isPowerPaused: isPowerPaused)
        let queueFileURL = self.queueFileURL
        let appSupportURL = self.appSupportURL

        Task.detached {
            do {
                try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(state)
                try data.write(to: queueFileURL, options: [.atomic])
            } catch {
                await MainActor.run {
                    self.appendActivity("Queue state could not be saved: \(error.localizedDescription)")
                }
            }
        }
    }
    func recoverRunningItems() {
        var changed = false
        for index in items.indices where items[index].status == .running {
            items[index].status = .queued
            items[index].statusMessage = isPowerPaused ? "Paused on battery; connect power to continue" : (isPaused ? "Paused after restart; resume to continue" : "Recovered after restart")
            items[index].recoveredAfterRestart = true
            items[index].updatedAt = Date()
            changed = true
        }
        if changed {
            appendActivity("Recovered running queue items after app restart.")
        }
    }
    func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.refreshFreeMemory()
                self?.refreshPowerSource()
                self?.startNextIfPossible()
            }
        }
        refreshFreeMemory()
        refreshPowerSource()
    }
    func appendActivity(_ line: String) {
        let timestamp = Self.activityFormatter.string(from: Date())
        recentActivity.insert("\(timestamp) \(line)", at: 0)
        if recentActivity.count > 80 {
            recentActivity.removeLast(recentActivity.count - 80)
        }
    }
    func writeControl(_ payload: [String: Bool]) {
        guard let activeControlFileURL else { return }
        Task.detached {
            do {
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                try data.write(to: activeControlFileURL, options: [.atomic])
            } catch {
                await MainActor.run {
                    self.appendActivity("Could not write control file: \(error.localizedDescription)")
                }
            }
        }
    }
    func controlFlagFromActiveFile(_ key: String) -> Bool {
        guard let activeControlFileURL,
              let data = try? Data(contentsOf: activeControlFileURL),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (decoded[key] as? Bool) == true
    }
    nonisolated func controlFlagFromActiveFileAsync(_ key: String, controlURL: URL?) async -> Bool {
        guard let url = controlURL else { return false }
        return await Task.detached {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return (decoded[key] as? Bool) == true
        }.value
    }
    func fetchInstalledModels(completion: @escaping (Set<String>, Bool) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else {
            completion([], false)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { data, _, error in
            Task.detached {
                guard error == nil, let data else {
                    await MainActor.run { completion([], false) }
                    return
                }
                let decoded = try? JSONDecoder().decode(QueueOllamaTagsResponse.self, from: data)
                let models = Set(decoded?.models.map(\.name) ?? [])
                let hasDecoded = decoded != nil
                await MainActor.run {
                    completion(models, hasDecoded)
                }
            }
        }.resume()
    }
    func cleanLocalModels(_ models: [String]) -> [String] {
        var seen = Set<String>()
        var cleaned: [String] = []
        for model in models {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, Self.isLocalStageModel(trimmed), !seen.contains(key) else { continue }
            cleaned.append(trimmed)
            seen.insert(key)
        }
        return cleaned
    }
    func normalizePrompt(_ prompt: String) -> String {
        prompt
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
    var stressScriptURL: URL {
        repoRootURL.appendingPathComponent("Scripts").appendingPathComponent("rus_to_prompt_stress.py")
    }
    func pythonPath() -> String {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3") {
            return "/opt/homebrew/bin/python3"
        }
        return "/usr/bin/python3"
    }
    nonisolated static func codexExecutablePath() -> String {
        ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"].first {
            FileManager.default.fileExists(atPath: $0)
        } ?? "codex"
    }
    nonisolated static func geminiExecutablePath() -> String {
        ["/opt/homebrew/bin/gemini", "/usr/local/bin/gemini", "/usr/bin/gemini"].first {
            FileManager.default.fileExists(atPath: $0)
        } ?? "gemini"
    }
    nonisolated static func searchPath(existing: String?) -> String {
        var parts = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let homeLocal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        parts.append(homeLocal)
        if let existing, !existing.isEmpty {
            parts.append(existing)
        }
        return parts.joined(separator: ":")
    }
    nonisolated static func timestampID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
    nonisolated static let activityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

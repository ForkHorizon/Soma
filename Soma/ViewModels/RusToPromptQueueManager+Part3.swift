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
        case "cooldown_start":
            return "\(caseID) cooldown started · \(event.reason ?? "")"
        case "cooldown_pause":
            return "\(caseID) cooldown paused"
        case "cooldown_complete":
            return "\(caseID) cooldown finished"
        case "result_write":
            return "\(caseID) result saved"
        default:
            return "\(caseID) \(displayStage(for: event)) · \(event.status ?? "")"
        }
    }


    func displayStage(for event: QueueProgressEvent) -> String {
        switch event.stage {
        case "queued": return "Queued"
        case "translating": return "Translating"
        case "translation_confidence", "translation_confidence_batch": return "Translation Check"
        case "translation_rejected": return "Translation Rejected"
        case "analyzing": return "Improving"
        case "improve_confidence_batch": return "Improve Confidence"
        case "overall_confidence_batch": return "Overall Confidence"
        case "cooldown": return "Cooldown"
        case "writing_result": return "Saving"
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


    func loadFromDisk() {
        do {
            try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: queueFileURL.path) else { return }
            let data = try Data(contentsOf: queueFileURL)
            let decoded = try JSONDecoder().decode(RusToPromptQueueDiskState.self, from: data)
            settings = decoded.settings
            items = decoded.items
        } catch {
            appendActivity("Queue state could not be loaded: \(error.localizedDescription)")
        }
    }


    func saveToDisk() {
        do {
            try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
            let state = RusToPromptQueueDiskState(settings: settings, items: items)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: queueFileURL, options: [.atomic])
        } catch {
            appendActivity("Queue state could not be saved: \(error.localizedDescription)")
        }
    }


    func recoverRunningItems() {
        var changed = false
        for index in items.indices where items[index].status == .running {
            items[index].status = .queued
            items[index].statusMessage = "Recovered after restart"
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
                self?.startNextIfPossible()
            }
        }
        refreshFreeMemory()
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
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: activeControlFileURL, options: [.atomic])
        } catch {
            appendActivity("Could not write control file: \(error.localizedDescription)")
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


    func fetchInstalledModels(completion: @escaping (Set<String>, Bool) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else {
            completion([], false)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                guard error == nil, let data else {
                    completion([], false)
                    return
                }
                let decoded = try? JSONDecoder().decode(QueueOllamaTagsResponse.self, from: data)
                completion(Set(decoded?.models.map(\.name) ?? []), decoded != nil)
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

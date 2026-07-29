import Combine
import Foundation

extension RusToPromptQueueManager {
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
            // Child still alive? Re-attach instead of re-spawning — avoids the duplicate
            // run_start/resume cycles that previously stacked up errors across restarts.
            if reattachRunningChildIfAlive(index: index) {
                changed = true
                continue
            }
            items[index].pid = nil
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


    /// Whether the queue has anything that needs the housekeeping timer: an
    /// active/reattached run, or any item still queued/running/waiting. When this
    /// is false the app is idle and should poll nothing.
    var hasLiveQueueWork: Bool {
        activeProcess != nil || activeReattachedPID != nil || activeItemID != nil
            || items.contains { $0.status == .queued || $0.status == .running || $0.status == .waitingLocalAI }
    }

    /// Start the 1s housekeeping timer only when there's live work and it isn't
    /// already running. Idle → no timer, no 5s RAM/power poll.
    func startTimerIfNeeded() {
        guard timer == nil, hasLiveQueueWork else { return }
        startTimer()
    }

    /// Stop the timer once the queue drains, so an idle app costs zero polling.
    func stopTimerIfIdle() {
        guard !hasLiveQueueWork else { return }
        timer?.invalidate()
        timer = nil
    }

    func startTimer() {
        // Tick fast for live progress (cheap file read + kill(pid,0)); run the heavier
        // memory/power/queue-advance housekeeping every 5th tick to keep its prior cadence.
        // The timer only runs while there is live work (see startTimerIfNeeded); it
        // stops itself once the queue is idle.
        timer?.invalidate()   // never stack a second 1s timer if called again
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pumpProgressLog()        // live progress comes from tailing progress.log
                self.pollReattachedExit()     // detect exit of a re-attached (Process-less) run
                self.progressTickCount += 1
                guard self.progressTickCount % 5 == 0 else { return }
                self.refreshFreeMemory()
                self.refreshPowerSource()
                self.startNextIfPossible()
                self.stopTimerIfIdle()        // drained → stop polling until new work
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

    func cleanStageModels(_ models: [String]) -> [String] {
        var seen = Set<String>()
        var cleaned: [String] = []
        for model in models {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, Self.isStageCandidateModel(trimmed), !seen.contains(key) else { continue }
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
}

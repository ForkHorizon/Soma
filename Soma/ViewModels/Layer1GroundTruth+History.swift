import Foundation

extension Layer1GroundTruthStore {
    func runsForLatestAttempts() -> [Layer1ModelRun] {
        var latest: [String: Layer1ModelRun] = [:]
        for run in state.modelRuns {
            let key = "\(run.audioID)#\(run.modelID)"
            if latest[key]?.attempt ?? 0 < run.attempt { latest[key] = run }
        }
        return Array(latest.values)
    }

    func recoverInterruptedRuns() { requeueInterruptedRuns() }

    func bootstrapCommandConfiguration() {
        guard !FileManager.default.fileExists(atPath: commandConfigurationURL.path) else { return }
        let empty = Dictionary(
            uniqueKeysWithValues: Layer1ModelSpec.catalog.map {
                ($0.id, ["version": "unconfigured", "command": ""])
            })
        let data = try? JSONSerialization.data(
            withJSONObject: empty, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: commandConfigurationURL, options: .atomic)
    }

    func commandConfiguration(for modelID: String) -> (command: [String], version: String) {
        guard let data = try? Data(contentsOf: commandConfigurationURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
            let row = object[modelID], let raw = row["command"] as? String,
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return ([], "unconfigured") }
        return (raw.split(separator: " ").map(String.init), row["version"] as? String ?? "unversioned")
    }

    func appendHistory(event: String, payload: [String: Any]) {
        var row = payload
        row["event"] = event
        row["at"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: row),
            var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        if let handle = try? FileHandle(forWritingTo: historyURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: historyURL)
        }
    }
}

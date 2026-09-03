import Foundation

extension Layer1GroundTruthStore {
    @discardableResult
    func save() -> Bool {
        guard canPersistState else { return false }
        state.updatedAt = Date()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: stateURL, options: .atomic)
            statePersistenceError = nil
            return true
        } catch {
            statePersistenceError = error.localizedDescription
            return false
        }
    }

    func writeHumanGoldIfComplete(audioID: String) {
        let segments = state.segments.filter { $0.audioID == audioID }
        guard let file = file(for: audioID), fullyVerifiedFileIDs().contains(audioID),
            let line = Self.humanGoldLine(
                audioID: audioID, fileName: file.url.lastPathComponent, segments: segments)
        else { return }
        updateHumanGold(audioID: audioID, fileName: file.url.lastPathComponent, line: line)
    }

    func removeHumanGold(audioID: String) {
        guard let file = file(for: audioID) else { return }
        updateHumanGold(audioID: audioID, fileName: file.url.lastPathComponent, line: nil)
    }

    private func updateHumanGold(audioID: String, fileName: String, line: String?) {
        let goldURL = directory.deletingLastPathComponent().appendingPathComponent("human/gold.jsonl")
        try? FileManager.default.createDirectory(
            at: goldURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rawContent: String
        if FileManager.default.fileExists(atPath: goldURL.path) {
            guard let content = try? String(contentsOf: goldURL, encoding: .utf8) else {
                statePersistenceError = "Human gold could not be read."
                return
            }
            rawContent = content
        } else {
            rawContent = ""
        }
        let existingLines = rawContent.split(separator: "\n", omittingEmptySubsequences: true).map(
            String.init)
        let legacyMatches = existingLines.filter { rawLine in
            guard let data = rawLine.data(using: .utf8),
                let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return row["audio_id"] == nil && row["file"] as? String == fileName
        }.count
        var updated = false
        var outputLines: [String] = []
        for rawLine in existingLines {
            guard let lineData = rawLine.data(using: .utf8),
                let row = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let rowFile = row["file"] as? String
            else {
                outputLines.append(rawLine)
                continue
            }
            let sameAudio = row["audio_id"] as? String == audioID
            let safeLegacyMatch = row["audio_id"] == nil && legacyMatches == 1 && rowFile == fileName
            if sameAudio || safeLegacyMatch {
                if let line { outputLines.append(line) }
                updated = true
            } else {
                outputLines.append(rawLine)
            }
        }
        if let line, !updated { outputLines.append(line) }
        guard line != nil || updated else { return }
        let outputText = outputLines.isEmpty ? "" : outputLines.joined(separator: "\n") + "\n"
        do {
            try Data(outputText.utf8).write(to: goldURL, options: .atomic)
        } catch {
            statePersistenceError = error.localizedDescription
        }
    }

    private static func humanGoldLine(
        audioID: String, fileName: String, segments: [Layer1Segment]
    ) -> String? {
        let object: [String: Any] = [
            "audio_id": audioID, "file": fileName, "text": Self.assemble(segments),
            "source": "layer1-human", "cycle": "layer1-v1",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func refreshStatuses() {
        for index in state.files.indices {
            state.files[index].lastStatus = status(for: state.files[index].id)
        }
        for index in state.batches.indices {
            let statuses = state.batches[index].fileIDs.map { status(for: $0) }
            if statuses.contains(.running) {
                state.batches[index].status = .running
            } else if statuses.contains(.queued) {
                state.batches[index].status = .queued
            } else if statuses.contains(.partial) {
                state.batches[index].status = .partial
            } else if statuses.allSatisfy({ $0 == .completed }) {
                state.batches[index].status = .completed
            } else {
                state.batches[index].status = .failed
            }
        }
    }

    static func loadState(from directory: URL) throws -> Layer1State {
        let data = try Data(contentsOf: directory.appendingPathComponent("state.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(Layer1State.self, from: data)
        guard state.schemaVersion == Layer1State.currentSchemaVersion else {
            throw NSError(
                domain: "Soma.Layer1State", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported state schema version."])
        }
        return state
    }
}

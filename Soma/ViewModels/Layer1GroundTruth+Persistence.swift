import Foundation

extension Layer1GroundTruthStore {
    func save() {
        state.updatedAt = Date()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    func writeHumanGoldIfComplete(audioID: String) {
        let segments = state.segments.filter { $0.audioID == audioID }
        guard let file = file(for: audioID), !segments.isEmpty,
            segments.allSatisfy({ $0.decision.status == .verified }),
            let line = Self.humanGoldLine(fileName: file.url.lastPathComponent, segments: segments)
        else { return }
        let goldURL = directory.deletingLastPathComponent().appendingPathComponent("human/gold.jsonl")
        try? FileManager.default.createDirectory(
            at: goldURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rawContent = (try? String(contentsOf: goldURL, encoding: .utf8)) ?? ""
        let existingLines = rawContent.split(separator: "\n", omittingEmptySubsequences: true).map(
            String.init)
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
            if rowFile == file.url.lastPathComponent {
                outputLines.append(line)
                updated = true
            } else {
                outputLines.append(rawLine)
            }
        }
        if !updated { outputLines.append(line) }
        let outputText = outputLines.joined(separator: "\n") + "\n"
        try? Data(outputText.utf8).write(to: goldURL, options: .atomic)
    }

    private static func humanGoldLine(fileName: String, segments: [Layer1Segment]) -> String? {
        let object: [String: Any] = [
            "file": fileName, "text": Self.assemble(segments),
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

    static func loadState(from directory: URL) -> Layer1State? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("state.json")) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Layer1State.self, from: data)
    }
}

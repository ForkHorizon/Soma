import CryptoKit
import Darwin
import Foundation

struct Layer2PreferredTranscript: Codable, Hashable, Identifiable {
    let id: String
    let audioID: String
    let fileName: String
    let verbatimText: String
    let audioHash: String?
    let sourceTextHash: String?
    var preferredText: String
    let createdAt: Date
    var updatedAt: Date
}

enum Layer2StorageError: LocalizedError {
    case sourceUnavailable
    case malformedLine(Int)
    case duplicateAudioID(String)
    case cannotEncode
    case lockUnavailable

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable: return "The verified Stage 1 source is no longer available."
        case .malformedLine(let line): return "Stage 2 storage has malformed data on line \(line)."
        case .duplicateAudioID(let id): return "Stage 2 storage has duplicate data for \(id)."
        case .cannotEncode: return "Stage 2 data could not be encoded."
        case .lockUnavailable: return "Stage 2 storage could not be locked safely."
        }
    }
}

extension Layer1GroundTruthStore {
    var stage2PreferredURL: URL {
        directory.deletingLastPathComponent()
            .appendingPathComponent("layer2", isDirectory: true)
            .appendingPathComponent("preferred.jsonl")
    }

    func stage2SourceText(audioID: String) -> String? {
        guard structurallyVerifiedFileIDs().contains(audioID),
            let file = file(for: audioID), currentAudioMatches(file)
        else { return nil }
        return stage2ReviewSourceText(audioID: audioID)
    }

    func stage2ReviewSourceText(audioID: String) -> String? {
        guard structurallyVerifiedFileIDs().contains(audioID) else { return nil }
        return Self.assemble(state.segments.filter { $0.audioID == audioID })
    }

    func stage2Transcript(audioID: String) -> Layer2PreferredTranscript? {
        do {
            return try stage2Transcripts().first {
                $0.audioID == audioID && isCurrent($0, audioID: audioID)
            }
        } catch {
            return nil
        }
    }

    func stage2Transcripts() throws -> [Layer2PreferredTranscript] {
        do {
            let entries = try withStage2Lock { try readStage2Transcripts() }
            stage2StorageError = nil
            return entries
        } catch {
            stage2StorageError = error.localizedDescription
            throw error
        }
    }

    func currentStage2Transcripts() throws -> [String: Layer2PreferredTranscript] {
        try stage2Transcripts().reduce(into: [String: Layer2PreferredTranscript]()) { result, entry in
            if isCurrent(entry, audioID: entry.audioID) { result[entry.audioID] = entry }
        }
    }

    @discardableResult
    func saveStage2Transcript(audioID: String, preferredText: String) throws -> Layer2PreferredTranscript {
        guard let file = file(for: audioID), let source = stage2SourceText(audioID: audioID)
        else { throw Layer2StorageError.sourceUnavailable }
        let now = Date()
        let entry = Layer2PreferredTranscript(
            id: audioID, audioID: audioID, fileName: file.url.lastPathComponent,
            verbatimText: source, audioHash: file.audioHash,
            sourceTextHash: Self.textHash(source), preferredText: preferredText,
            createdAt: now, updatedAt: now)
        let result = try withStage2Lock {
            let existingEntries = try readStage2Transcripts()
            let existing = existingEntries.first { $0.audioID == audioID }
            var entries = existingEntries.filter { $0.audioID != audioID }
            let result = Layer2PreferredTranscript(
                id: entry.id, audioID: entry.audioID, fileName: entry.fileName,
                verbatimText: entry.verbatimText, audioHash: entry.audioHash,
                sourceTextHash: entry.sourceTextHash, preferredText: entry.preferredText,
                createdAt: existing?.createdAt ?? now, updatedAt: entry.updatedAt)
            entries.append(result)
            try writeStage2Transcripts(entries)
            return result
        }
        stage2StorageError = nil
        return result
    }

    func invalidateStage2Transcript(audioID: String) {
        do {
            try withStage2Lock {
                let current = try readStage2Transcripts()
                guard current.contains(where: { $0.audioID == audioID }) else { return }
                let entries = current.filter { $0.audioID != audioID }
                try writeStage2Transcripts(entries)
            }
            stage2StorageError = nil
        } catch {
            stage2StorageError = error.localizedDescription
        }
    }

    private func isCurrent(_ entry: Layer2PreferredTranscript, audioID: String) -> Bool {
        guard let file = file(for: audioID), let source = stage2SourceText(audioID: audioID),
            entry.audioHash == file.audioHash, entry.sourceTextHash == Self.textHash(source)
        else { return false }
        return entry.verbatimText == source
    }

    private func readStage2Transcripts() throws -> [Layer2PreferredTranscript] {
        guard FileManager.default.fileExists(atPath: stage2PreferredURL.path) else { return [] }
        let content = try String(contentsOf: stage2PreferredURL, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var lines = content.components(separatedBy: .newlines)
        if lines.last == "" { lines.removeLast() }
        var seen = Set<String>()
        return try lines.enumerated().map { index, line in
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Layer2StorageError.malformedLine(index + 1)
            }
            guard
                let entry = try? decoder.decode(
                    Layer2PreferredTranscript.self, from: Data(line.utf8))
            else { throw Layer2StorageError.malformedLine(index + 1) }
            guard seen.insert(entry.audioID).inserted else {
                throw Layer2StorageError.duplicateAudioID(entry.audioID)
            }
            return entry
        }
    }

    private func writeStage2Transcripts(_ entries: [Layer2PreferredTranscript]) throws {
        try FileManager.default.createDirectory(
            at: stage2PreferredURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: stage2PreferredURL.path) {
            let backup = stage2PreferredURL.appendingPathExtension("bak")
            try Data(contentsOf: stage2PreferredURL).write(to: backup, options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let lines = try entries.sorted { $0.fileName < $1.fileName }.map { entry -> String in
            guard let data = try? encoder.encode(entry), let line = String(data: data, encoding: .utf8)
            else { throw Layer2StorageError.cannotEncode }
            return line
        }
        try Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
            .write(to: stage2PreferredURL, options: .atomic)
    }

    private func withStage2Lock<T>(_ body: () throws -> T) throws -> T {
        Self.stage2Lock.lock()
        defer { Self.stage2Lock.unlock() }
        let lockURL = stage2PreferredURL.appendingPathExtension("lock")
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Layer2StorageError.lockUnavailable }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else { throw Layer2StorageError.lockUnavailable }
        return try body()
    }

    private static let stage2Lock = NSLock()

    private static func textHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

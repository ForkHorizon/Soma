import XCTest

@testable import Soma

final class Layer1DeletionTests: XCTestCase {
    func testResetRemovesAllLayerDataButKeepsAudio() throws {
        let root = try makeTempDirectory()
        let audio = root.appendingPathComponent("speech.wav")
        try Data("speech".utf8).write(to: audio)
        try Data("speech text".utf8).write(to: root.appendingPathComponent("speech.txt"))
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        let fileID = try addVerifiedFile(audio, to: store)
        let batchID = "batch"
        store.state.files[0].batchIDs = [batchID]
        store.state.batches = [
            Layer1Batch(
                id: batchID, createdAt: Date(), requestedCount: 1, fileIDs: [fileID], status: .completed)
        ]
        try store.saveStage2Transcript(audioID: fileID, preferredText: "preferred")
        let manifestDirectory = store.directory.appendingPathComponent("batch-manifests")
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        let manifest = manifestDirectory.appendingPathComponent("\(batchID)-model.jsonl")
        try Data("manifest".utf8).write(to: manifest)

        _ = try store.removeLayer1Results(audioIDs: Set([fileID]))

        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("speech.txt").path))
        XCTAssertTrue(store.state.files.isEmpty)
        XCTAssertTrue(store.state.modelRuns.isEmpty)
        XCTAssertTrue(store.state.segments.isEmpty)
        XCTAssertTrue(store.state.batches.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertNil(store.stage2Transcript(audioID: fileID))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("human/gold.jsonl"), encoding: .utf8), "")
        let history = try String(contentsOf: store.historyURL, encoding: .utf8)
        XCTAssertTrue(history.contains("layer1_results_removed"))
        XCTAssertFalse(history.contains("rawResponse"))
        let reloaded = Layer1GroundTruthStore(directory: store.directory)
        XCTAssertTrue(reloaded.state.files.isEmpty)
        XCTAssertTrue(reloaded.state.modelRuns.isEmpty)
        XCTAssertTrue(reloaded.state.segments.isEmpty)
        XCTAssertNotNil(
            store.addBatch(
                count: 1, candidates: [Layer1AudioCandidate(url: audio, date: Date(), duration: 1)]))
    }

    func testPhysicalDeletionRemovesAudioAndTranscriptAndRejectsOutsidePath() throws {
        let root = try makeTempDirectory()
        let recordings = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let audio = recordings.appendingPathComponent("bad.wav")
        let transcript = recordings.appendingPathComponent("bad.txt")
        try Data("audio".utf8).write(to: audio)
        try Data("text".utf8).write(to: transcript)

        try ASRManager.removeRecording(at: audio, from: recordings)

        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcript.path))
        let missing = recordings.appendingPathComponent("missing.wav")
        let missingTranscript = recordings.appendingPathComponent("missing.txt")
        try Data("text".utf8).write(to: missingTranscript)
        try ASRManager.removeRecording(at: missing, from: recordings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingTranscript.path))
        XCTAssertThrowsError(
            try ASRManager.removeRecording(
                at: root.appendingPathComponent("outside.wav"), from: recordings))
    }

    func testRemoveAllRecordingsDeletesTrackedAndUntrackedAudio() throws {
        let root = try makeTempDirectory()
        let recordings = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let first = recordings.appendingPathComponent("first.wav")
        let second = recordings.appendingPathComponent("second.wav")
        try Data("wav".utf8).write(to: first)
        try Data("wav".utf8).write(to: second)
        try Data("txt".utf8).write(to: first.deletingPathExtension().appendingPathExtension("txt"))
        let orphanTranscript = recordings.appendingPathComponent("orphan.txt")
        try Data("orphan".utf8).write(to: orphanTranscript)
        let notes = recordings.appendingPathComponent("notes.json")
        try Data("keep".utf8).write(to: notes)

        XCTAssertEqual(try ASRManager.removeAllRecordings(in: recordings), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanTranscript.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.path))
    }

    func testStage2DeletionRemovesDeletedIDsFromBackup() throws {
        let root = try makeTempDirectory()
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        let first = try addVerifiedFile(root.appendingPathComponent("first.wav"), to: store)
        let secondAudio = root.appendingPathComponent("second.wav")
        try Data("second".utf8).write(to: secondAudio)
        let second = try addVerifiedFile(secondAudio, to: store)

        try store.saveStage2Transcript(audioID: first, preferredText: "first")
        try store.saveStage2Transcript(audioID: second, preferredText: "second")
        try store.removeStage2Transcripts(audioIDs: Set([first]))

        let current = try String(contentsOf: store.stage2PreferredURL, encoding: .utf8)
        let backup = try String(
            contentsOf: store.stage2PreferredURL.appendingPathExtension("bak"), encoding: .utf8)
        XCTAssertFalse(current.contains("first"))
        XCTAssertFalse(backup.contains("first"))
        XCTAssertTrue(current.contains("second"))
        XCTAssertTrue(backup.contains("second"))
    }

    private func addVerifiedFile(_ audio: URL, to store: Layer1GroundTruthStore) throws -> String {
        try Data("audio".utf8).write(to: audio)
        let id = audio.path
        store.state.files.append(
            Layer1AudioFile(
                id: id, path: id, audioHash: Layer1GroundTruthStore.sha256(file: audio), duration: 1,
                addedAt: Date(), batchIDs: [], lastStatus: .completed))
        store.state.modelRuns.append(
            Layer1ModelRun(
                id: "(id)#run", audioID: id, modelID: "test-model", model: "Test",
                family: "Test", version: "1", configuration: [:], startedAt: Date(),
                finishedAt: Date(), duration: 1, attempt: 1, status: .completed,
                rawResponse: "raw-response", text: "reference", wordTimestamps: [], error: nil))
        let segmentID = "\(id)#segment"
        store.state.segments.append(
            Layer1Segment(
                id: segmentID, audioID: id, start: 0, end: 1,
                segmentationAlgorithmVersion: "test", sourceWordRange: nil, modelSuggestions: [:],
                proposalOrder: [], segmentationNeedsReview: false,
                decision: .init(
                    status: .verified, text: "reference", normalizedText: "reference", action: .manual,
                    sourceModelID: nil, createdAt: nil, updatedAt: nil)))
        store.saveDecision(segmentID: segmentID, text: "reference", action: .manual)
        return id
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

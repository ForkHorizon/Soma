import XCTest

@testable import Soma

final class Layer1GroundTruthPersistenceTests: XCTestCase {
    func testUnconfiguredOptionalModelDoesNotJoinNewBatch() throws {
        let root = try makeTempDirectory()
        let audio = root.appendingPathComponent("speech.wav")
        try Data("speech".utf8).write(to: audio)
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))

        _ = store.addBatch(
            count: 1,
            candidates: [Layer1AudioCandidate(url: audio, date: Date(), duration: 1)])

        XCTAssertEqual(store.queuedRuns().count, store.activeModelIDs.count)
        XCTAssertFalse(store.queuedRuns().contains { $0.modelID == "gigaam-multilingual" })
    }

    func testSegmentsPreferPausesAndStayUnderTenWords() {
        let words = (0..<12).map {
            Layer1WordTimestamp(
                word: "слово\($0)", start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.2)
        }
        let segments = Layer1GroundTruthStore.makeSegments(
            audioID: "audio", duration: 20, words: words, suggestions: [:])

        XCTAssertEqual(segments.compactMap { $0.sourceWordRange?.count }, [9, 3])
        XCTAssertTrue(segments.allSatisfy { !$0.segmentationNeedsReview })

        let pausedWords = [
            Layer1WordTimestamp(word: "раз", start: 0, end: 0.2),
            Layer1WordTimestamp(word: "два", start: 0.4, end: 0.6),
            Layer1WordTimestamp(word: "три", start: 0.8, end: 1.0),
            Layer1WordTimestamp(word: "четыре", start: 2.0, end: 2.2),
            Layer1WordTimestamp(word: "пять", start: 2.4, end: 2.6),
        ]
        let pausedSegments = Layer1GroundTruthStore.makeSegments(
            audioID: "paused", duration: 4, words: pausedWords, suggestions: [:])
        XCTAssertEqual(pausedSegments.compactMap { $0.sourceWordRange?.count }, [3, 2])
        XCTAssertEqual(pausedSegments.first?.start ?? -1, 0)
        XCTAssertEqual(pausedSegments.last?.end ?? -1, 4)
        XCTAssertEqual(pausedSegments[0].end, pausedSegments[1].start)
    }

    func testFallbackSegmentsCoverWholeAudioWithoutTimestamps() {
        let duration = 34.2
        let segments = Layer1GroundTruthStore.makeSegments(
            audioID: "audio", duration: duration, words: [], suggestions: [:])

        XCTAssertEqual(segments.count, 6)
        XCTAssertEqual(segments.first?.start ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(segments.last?.end ?? -1, duration, accuracy: 0.0001)
        for pair in zip(segments, segments.dropFirst()) {
            XCTAssertEqual(pair.0.end, pair.1.start, accuracy: 0.0001)
        }
    }

    func testStage2StoresPreferredTextSeparatelyFromVerbatimSource() throws {
        let root = try makeTempDirectory()
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        let audioID = "audio"
        let audio = root.appendingPathComponent("speech.wav")
        try Data("speech".utf8).write(to: audio)
        store.state.files = [
            Layer1AudioFile(
                id: audioID, path: audio.path, audioHash: Layer1GroundTruthStore.sha256(file: audio), duration: 1,
                addedAt: Date(), batchIDs: [], lastStatus: .completed)
        ]
        store.state.segments = [
            Layer1Segment(
                id: "segment", audioID: audioID, start: 0, end: 1,
                segmentationAlgorithmVersion: "layer1-seg-v2:0", sourceWordRange: nil,
                modelSuggestions: [:], proposalOrder: [], segmentationNeedsReview: false,
                decision: .init(
                    status: .verified, text: "что что что", normalizedText: "что что что",
                    action: .manual, sourceModelID: nil, createdAt: nil, updatedAt: nil))
        ]

        try store.saveStage2Transcript(audioID: audioID, preferredText: "Что!")

        let entry = try XCTUnwrap(store.stage2Transcript(audioID: audioID))
        XCTAssertEqual(entry.verbatimText, "что что что")
        XCTAssertEqual(entry.preferredText, "Что!")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.stage2PreferredURL.path))
        try store.saveStage2Transcript(audioID: audioID, preferredText: "Что? что?")
        let backup = store.stage2PreferredURL.appendingPathExtension("bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(try String(contentsOf: backup, encoding: .utf8).contains("Что!"))
    }

    func testStage2RejectsMissingAudioAndKeepsCorruptStorage() throws {
        let root = try makeTempDirectory()
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        XCTAssertThrowsError(try store.saveStage2Transcript(audioID: "missing", preferredText: "text"))

        try FileManager.default.createDirectory(
            at: store.stage2PreferredURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("not-json\n".utf8)
        try corrupt.write(to: store.stage2PreferredURL)
        XCTAssertThrowsError(try store.stage2Transcripts())
        XCTAssertEqual(try Data(contentsOf: store.stage2PreferredURL), corrupt)
        XCTAssertThrowsError(try store.saveStage2Transcript(audioID: "missing", preferredText: "text"))
        XCTAssertEqual(try Data(contentsOf: store.stage2PreferredURL), corrupt)
        try Data("\n".utf8).write(to: store.stage2PreferredURL)
        XCTAssertThrowsError(try store.stage2Transcripts())
    }

    func testStage2RejectsDuplicateEntries() throws {
        let root = try makeTempDirectory()
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        try FileManager.default.createDirectory(
            at: store.stage2PreferredURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line =
            "{\"id\":\"a\",\"audioID\":\"a\",\"fileName\":\"a.wav\",\"verbatimText\":\"a\",\"audioHash\":null,\"sourceTextHash\":null,\"preferredText\":\"a\",\"createdAt\":\"2026-01-01T00:00:00Z\",\"updatedAt\":\"2026-01-01T00:00:00Z\"}"
        try Data("\(line)\n\(line)\n".utf8).write(to: store.stage2PreferredURL)

        XCTAssertThrowsError(try store.stage2Transcripts())
    }

    func testStage2IsInvalidatedWhenStage1Changes() throws {
        let root = try makeTempDirectory()
        let audio = root.appendingPathComponent("speech.wav")
        try Data("speech".utf8).write(to: audio)
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        store.state.files = [
            Layer1AudioFile(
                id: audio.path, path: audio.path,
                audioHash: Layer1GroundTruthStore.sha256(file: audio), duration: 1,
                addedAt: Date(), batchIDs: [], lastStatus: .completed)
        ]
        store.state.segments = [
            Layer1Segment(
                id: "segment", audioID: audio.path, start: 0, end: 1,
                segmentationAlgorithmVersion: "layer1-seg-v2:0", sourceWordRange: nil,
                modelSuggestions: [:], proposalOrder: [], segmentationNeedsReview: false,
                decision: .init(
                    status: .verified, text: "старый", normalizedText: "старый", action: .manual,
                    sourceModelID: nil, createdAt: nil, updatedAt: nil))
        ]
        try store.saveStage2Transcript(audioID: audio.path, preferredText: "предпочтительный")
        XCTAssertNotNil(store.stage2Transcript(audioID: audio.path))

        store.saveDecision(segmentID: "segment", text: "новый", action: .manual)

        XCTAssertNil(store.stage2Transcript(audioID: audio.path))
    }

    func testStage2RejectsChangedAudio() throws {
        let root = try makeTempDirectory()
        let audio = root.appendingPathComponent("speech.wav")
        try Data("speech".utf8).write(to: audio)
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        store.state.files = [
            Layer1AudioFile(
                id: audio.path, path: audio.path,
                audioHash: Layer1GroundTruthStore.sha256(file: audio), duration: 1,
                addedAt: Date(), batchIDs: [], lastStatus: .completed)
        ]
        store.state.segments = [
            Layer1Segment(
                id: "segment", audioID: audio.path, start: 0, end: 1,
                segmentationAlgorithmVersion: "layer1-seg-v2:0", sourceWordRange: nil,
                modelSuggestions: [:], proposalOrder: [], segmentationNeedsReview: false,
                decision: .init(
                    status: .verified, text: "текст", normalizedText: "текст", action: .manual,
                    sourceModelID: nil, createdAt: nil, updatedAt: nil))
        ]
        try store.saveStage2Transcript(audioID: audio.path, preferredText: "текст")
        try Data("changed audio".utf8).write(to: audio)

        XCTAssertNil(store.stage2SourceText(audioID: audio.path))
        XCTAssertNil(store.stage2Transcript(audioID: audio.path))
    }

    func testStage2RejectsSegmentExtendingPastAudio() throws {
        let root = try makeTempDirectory()
        let audio = root.appendingPathComponent("speech.wav")
        try Data("speech".utf8).write(to: audio)
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        store.state.files = [
            Layer1AudioFile(
                id: audio.path, path: audio.path,
                audioHash: Layer1GroundTruthStore.sha256(file: audio), duration: 1,
                addedAt: Date(), batchIDs: [], lastStatus: .completed)
        ]
        store.state.segments = [
            Layer1Segment(
                id: "segment", audioID: audio.path, start: 0, end: 2,
                segmentationAlgorithmVersion: "layer1-seg-v2:0", sourceWordRange: nil,
                modelSuggestions: [:], proposalOrder: [], segmentationNeedsReview: false,
                decision: .init(
                    status: .verified, text: "текст", normalizedText: "текст", action: .manual,
                    sourceModelID: nil, createdAt: nil, updatedAt: nil))
        ]

        XCTAssertNil(store.stage2SourceText(audioID: audio.path))
        XCTAssertFalse(store.fullyVerifiedFileIDs().contains(audio.path))
    }

    func testHumanGoldUsesAudioIDWhenFileNamesRepeat() throws {
        let root = try makeTempDirectory()
        let firstURL = root.appendingPathComponent("one/speech.wav")
        let secondURL = root.appendingPathComponent("two/speech.wav")
        try FileManager.default.createDirectory(at: firstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: firstURL)
        try Data("two".utf8).write(to: secondURL)
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        store.state.files = [firstURL, secondURL].map { url in
            Layer1AudioFile(
                id: url.path, path: url.path, audioHash: Layer1GroundTruthStore.sha256(file: url),
                duration: 1, addedAt: Date(), batchIDs: [], lastStatus: .completed)
        }
        store.state.segments = [firstURL, secondURL].enumerated().map { index, url in
            Layer1Segment(
                id: "segment-\(index)", audioID: url.path, start: 0, end: 1,
                segmentationAlgorithmVersion: "layer1-seg-v2:0", sourceWordRange: nil,
                modelSuggestions: [:], proposalOrder: [], segmentationNeedsReview: false,
                decision: .init(
                    status: .pending, text: nil, normalizedText: nil, action: nil,
                    sourceModelID: nil, createdAt: nil, updatedAt: nil))
        }
        store.saveDecision(segmentID: "segment-0", text: "один", action: .manual)
        store.saveDecision(segmentID: "segment-1", text: "два", action: .manual)

        let gold = try String(
            contentsOf: root.appendingPathComponent("human/gold.jsonl"), encoding: .utf8)
        XCTAssertEqual(gold.split(separator: "\n").count, 2)
        XCTAssertTrue(gold.contains(firstURL.path))
        XCTAssertTrue(gold.contains(secondURL.path))
    }

    func testSegmentMigrationDoesNotDeleteVerifiedDecisions() {
        let store = Layer1GroundTruthStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let audioID = "audio"
        store.state.files = [
            Layer1AudioFile(
                id: audioID, path: audioID, audioHash: "hash", duration: 4,
                addedAt: Date(), batchIDs: [], lastStatus: .completed)
        ]
        store.state.modelRuns = store.activeModelSpecs.map { spec in
            Layer1ModelRun(
                id: spec.id, audioID: audioID, modelID: spec.id, model: spec.title, family: spec.family,
                version: "test", configuration: spec.configuration, startedAt: nil, finishedAt: nil,
                duration: 4, attempt: 1, status: .completed, rawResponse: "{}", text: "text",
                wordTimestamps: [], error: nil)
        }
        let decision = Layer1SegmentDecision(
            status: .verified, text: "сохранить", normalizedText: "сохранить", action: .manual,
            sourceModelID: nil, createdAt: nil, updatedAt: nil)
        store.state.segments = [
            Layer1Segment(
                id: "verified", audioID: audioID, start: 0, end: 1,
                segmentationAlgorithmVersion: "layer1-seg-v1:0", sourceWordRange: nil,
                modelSuggestions: [:], proposalOrder: [], segmentationNeedsReview: false,
                decision: decision),
            Layer1Segment(
                id: "pending", audioID: audioID, start: 1, end: 4,
                segmentationAlgorithmVersion: "layer1-seg-v1:1", sourceWordRange: nil,
                modelSuggestions: [:], proposalOrder: [], segmentationNeedsReview: false,
                decision: .init(
                    status: .pending, text: nil, normalizedText: nil, action: nil,
                    sourceModelID: nil, createdAt: nil, updatedAt: nil)),
        ]

        store.rebuildPendingSegmentsIfNeeded()

        XCTAssertEqual(store.state.segments.map(\.id), ["verified", "pending"])
        XCTAssertEqual(store.state.segments.first?.decision.text, "сохранить")
    }

    func testMalformedStateIsNotOverwritten() throws {
        let root = try makeTempDirectory()
        let directory = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateURL = directory.appendingPathComponent("state.json")
        let original = Data("{\"broken\":true}\n".utf8)
        try original.write(to: stateURL)

        let store = Layer1GroundTruthStore(directory: directory)

        XCTAssertNotNil(store.stateLoadError)
        XCTAssertEqual(try Data(contentsOf: stateURL), original)
        store.save()
        XCTAssertEqual(try Data(contentsOf: stateURL), original)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

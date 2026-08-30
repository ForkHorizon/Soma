import XCTest

@testable import Soma

final class Layer1GroundTruthTests: XCTestCase {
    func testNormalizationKeepsSpokenWordsAndRepeats() {
        XCTAssertEqual(
            Layer1GroundTruthStore.normalize("Я,  я думаю... Что это правильно!"),
            "я я думаю что это правильно")
        XCTAssertEqual(Layer1GroundTruthStore.normalize("C++  C#"), "c++ c#")
    }

    func testBatchAddsOnlyNewFilesAndPersistsAcrossReload() throws {
        let root = try makeTempDirectory()
        let urls = (1...35).map { root.appendingPathComponent("rec-\($0).wav") }
        for (index, url) in urls.enumerated() { try Data("audio-\(index)".utf8).write(to: url) }
        let candidates = urls.map { Layer1AudioCandidate(url: $0, date: Date(), duration: 2) }
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))

        XCTAssertEqual(store.addBatch(count: 10, candidates: candidates)?.fileIDs.count, 10)
        XCTAssertEqual(store.addBatch(count: 10, candidates: candidates)?.fileIDs.count, 10)
        XCTAssertEqual(store.addBatch(count: 15, candidates: candidates)?.fileIDs.count, 15)
        XCTAssertNil(store.addBatch(count: 1, candidates: candidates))
        XCTAssertEqual(store.state.files.count, 35)

        let reloaded = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        XCTAssertEqual(reloaded.state.files.count, 35)
        XCTAssertEqual(reloaded.state.batches.map(\.fileIDs.count), [10, 10, 15])
        XCTAssertTrue(FileManager.default.fileExists(atPath: reloaded.historyURL.path))
    }

    func testModelAgreementNeverAutoAcceptsAndHistoryIsAppendOnly() throws {
        let root = try makeTempDirectory()
        let audio = root.appendingPathComponent("speech.wav")
        try Data("speech".utf8).write(to: audio)
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        let file = try XCTUnwrap(
            store.addBatch(
                count: 1,
                candidates: [
                    Layer1AudioCandidate(url: audio, date: Date(), duration: 4)
                ])?.fileIDs.first)
        let timestamp = [
            Layer1WordTimestamp(word: "я", start: 0, end: 0.4),
            Layer1WordTimestamp(word: "я", start: 0.5, end: 0.9),
            Layer1WordTimestamp(word: "думаю", start: 1, end: 1.5),
        ]
        for (index, run) in store.queuedRuns().enumerated() {
            store.markRunning(run.id, configuration: run.configuration, version: "test", at: Date())
            store.finish(
                run.id,
                completion: .init(
                    status: .completed, version: "test", rawResponse: "{\"text\":\"я я думаю\"}",
                    text: "я я думаю", timestamps: index == 0 ? timestamp : [], error: nil, duration: 0.1))
        }
        let segment = try XCTUnwrap(store.state.segments.first(where: { $0.audioID == file }))
        XCTAssertEqual(segment.decision.status, .pending)
        XCTAssertEqual(store.verifiedSegmentsCount(), 0)

        store.saveDecision(segmentID: segment.id, text: "Я я думаю", action: .manual)
        XCTAssertEqual(store.state.segments.first?.decision.normalizedText, "я я думаю")
        XCTAssertEqual(store.verifiedSegmentsCount(), 1)
        var gold = try String(
            contentsOf: root.appendingPathComponent("human/gold.jsonl"), encoding: .utf8)
        XCTAssertTrue(gold.contains("\"source\":\"layer1-human\""))
        XCTAssertTrue(gold.contains("\"text\":\"Я я думаю\""))

        store.saveDecision(segmentID: segment.id, text: "Я я думаю точно", action: .manual)
        gold = try String(contentsOf: root.appendingPathComponent("human/gold.jsonl"), encoding: .utf8)
        XCTAssertTrue(gold.contains("\"text\":\"Я я думаю точно\""))
        XCTAssertFalse(gold.contains("\"text\":\"Я я думаю\""))
        XCTAssertEqual(gold.split(separator: "\n").count, 1)

        let history = try String(contentsOf: store.historyURL, encoding: .utf8)
        XCTAssertGreaterThanOrEqual(history.split(separator: "\n").count, 15)
    }

    func testAssemblyUsesEachSegmentOnceAndPreservesOrder() {
        let suggestions: [String: Layer1ModelSuggestion] = [:]
        let first = Layer1Segment(
            id: "b", audioID: "a", start: 2, end: 3, segmentationAlgorithmVersion: "v1",
            sourceWordRange: 2..<3, modelSuggestions: suggestions, proposalOrder: [],
            segmentationNeedsReview: false,
            decision: Layer1SegmentDecision(
                status: .verified, text: "это", normalizedText: "это",
                action: .manual, sourceModelID: nil, createdAt: nil, updatedAt: nil))
        let second = Layer1Segment(
            id: "a", audioID: "a", start: 0, end: 1, segmentationAlgorithmVersion: "v1",
            sourceWordRange: 0..<2, modelSuggestions: suggestions, proposalOrder: [],
            segmentationNeedsReview: false,
            decision: Layer1SegmentDecision(
                status: .verified, text: "я я", normalizedText: "я я",
                action: .manual, sourceModelID: nil, createdAt: nil, updatedAt: nil))
        XCTAssertEqual(Layer1GroundTruthStore.assemble([first, second]), "я я это")
    }

    func testQualityUsesOnlyVerifiedHumanReference() {
        let model = Layer1ModelSpec.catalog[0]
        let suggestion = Layer1ModelSuggestion(
            modelID: model.id, model: model.title, status: .completed,
            text: "Я я думаю", error: nil, runID: "run")
        let verified = Layer1Segment(
            id: "verified", audioID: "audio", start: 0, end: 1,
            segmentationAlgorithmVersion: "v1", sourceWordRange: nil,
            modelSuggestions: [model.id: suggestion], proposalOrder: [model.id],
            segmentationNeedsReview: false,
            decision: .init(
                status: .verified, text: "я я думаю", normalizedText: "я я думаю",
                action: .selectedModel, sourceModelID: model.id, createdAt: nil, updatedAt: nil))
        let pending = Layer1Segment(
            id: "pending", audioID: "audio", start: 1, end: 2,
            segmentationAlgorithmVersion: "v1", sourceWordRange: nil,
            modelSuggestions: [model.id: suggestion], proposalOrder: [model.id],
            segmentationNeedsReview: false,
            decision: .init(
                status: .pending, text: nil, normalizedText: nil,
                action: nil, sourceModelID: nil, createdAt: nil, updatedAt: nil))

        let quality = layer1Quality(models: [model], segments: [verified, pending])[model.id]
        XCTAssertEqual(quality?.evaluated, 1)
        XCTAssertEqual(quality?.exact, 1)
        XCTAssertEqual(quality?.accepted, 1)
    }

    func testFfmpegEnvironmentFailuresAreRequeuedOnRecovery() throws {
        let root = try makeTempDirectory()
        let audio = root.appendingPathComponent("speech.wav")
        try Data("speech".utf8).write(to: audio)
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        _ = store.addBatch(
            count: 1, candidates: [Layer1AudioCandidate(url: audio, date: Date(), duration: 4)])
        let run = try XCTUnwrap(store.queuedRuns().first)
        store.markRunning(run.id, configuration: run.configuration, version: "test", at: Date())
        store.finish(
            run.id,
            completion: .init(
                status: .failed, version: "test", rawResponse: "", text: nil,
                timestamps: [], error: "FileNotFoundError: ffmpeg", duration: 0.1))

        let reloaded = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        let retry = reloaded.queuedRuns().first {
            $0.audioID == run.audioID && $0.modelID == run.modelID
        }
        XCTAssertEqual(retry?.attempt, 2)
    }

    func testRetryFailedRequeuesTheWholeUserBatch() throws {
        let root = try makeTempDirectory()
        let audio = root.appendingPathComponent("speech.wav")
        try Data("speech".utf8).write(to: audio)
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        let batch = try XCTUnwrap(
            store.addBatch(
                count: 1,
                candidates: [
                    Layer1AudioCandidate(url: audio, date: Date(), duration: 4)
                ]))
        let failed = try XCTUnwrap(store.queuedRuns().first)
        store.markRunning(failed.id, configuration: failed.configuration, version: "test", at: Date())
        store.finish(
            failed.id,
            completion: .init(
                status: .failed, version: "test", rawResponse: "", text: nil,
                timestamps: [], error: "model failed", duration: 0.1))

        store.retryFailed()
        XCTAssertEqual(store.latestRuns(for: batch.id).count, Layer1ModelSpec.catalog.count)
        XCTAssertTrue(
            store.latestRuns(for: batch.id).allSatisfy { $0.status == .queued && $0.attempt == 2 })
    }

    func testFailBatchInvalidatesSegmentsAndAllLatestRuns() throws {
        let root = try makeTempDirectory()
        let audio = root.appendingPathComponent("speech.wav")
        try Data("speech".utf8).write(to: audio)
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        let batch = try XCTUnwrap(
            store.addBatch(
                count: 1,
                candidates: [
                    Layer1AudioCandidate(url: audio, date: Date(), duration: 4)
                ]))
        for run in store.queuedRuns() {
            store.markRunning(run.id, configuration: run.configuration, version: "test", at: Date())
            store.finish(
                run.id,
                completion: .init(
                    status: .completed, version: "test", rawResponse: "{}", text: "слово",
                    timestamps: [], error: nil, duration: 0.1))
        }
        XCTAssertFalse(store.state.segments.isEmpty)
        store.failBatch(batch.id, error: "one model failed")
        XCTAssertTrue(store.state.segments.isEmpty)
        XCTAssertTrue(store.latestRuns(for: batch.id).allSatisfy { $0.status == .failed })
    }

    func testPartialQueuedBatchRecoveryInvalidatesOldSegments() throws {
        let root = try makeTempDirectory()
        let audio = root.appendingPathComponent("speech.wav")
        try Data("speech".utf8).write(to: audio)
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        let batch = try XCTUnwrap(
            store.addBatch(
                count: 1,
                candidates: [
                    Layer1AudioCandidate(url: audio, date: Date(), duration: 4)
                ]))
        let run = try XCTUnwrap(store.queuedRuns().first)
        store.markRunning(run.id, configuration: run.configuration, version: "test", at: Date())
        store.finish(
            run.id,
            completion: .init(
                status: .completed, version: "test", rawResponse: "{}", text: "слово",
                timestamps: [], error: nil, duration: 0.1))

        let reloaded = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        XCTAssertTrue(reloaded.latestRuns(for: batch.id).allSatisfy { $0.status == .queued })
        XCTAssertEqual(
            reloaded.latestRuns(for: batch.id).first { $0.modelID == run.modelID }?.attempt, 2)
        XCTAssertTrue(reloaded.state.segments.isEmpty)
    }

    func testReviewSegmentsChronologicalOrderAboveTenSeconds() throws {
        let root = try makeTempDirectory()
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        let suggestions: [String: Layer1ModelSuggestion] = [:]
        let late = Layer1Segment(
            id: "audio#10.0#12.0", audioID: "audio", start: 10.0, end: 12.0,
            segmentationAlgorithmVersion: "v1", sourceWordRange: nil,
            modelSuggestions: suggestions, proposalOrder: [], segmentationNeedsReview: false,
            decision: .init(
                status: .pending, text: nil, normalizedText: nil, action: nil,
                sourceModelID: nil, createdAt: nil, updatedAt: nil))
        let early = Layer1Segment(
            id: "audio#2.0#4.0", audioID: "audio", start: 2.0, end: 4.0,
            segmentationAlgorithmVersion: "v1", sourceWordRange: nil,
            modelSuggestions: suggestions, proposalOrder: [], segmentationNeedsReview: false,
            decision: .init(
                status: .pending, text: nil, normalizedText: nil, action: nil,
                sourceModelID: nil, createdAt: nil, updatedAt: nil))
        store.state.segments = [late, early]
        let review = store.segmentsForReview()
        XCTAssertEqual(review.map(\.start), [2.0, 10.0])
    }

    func testTimedModelsDoNotLeakFullTranscriptIntoEmptySegments() throws {
        let root = try makeTempDirectory()
        let audio = root.appendingPathComponent("speech.wav")
        try Data("speech".utf8).write(to: audio)
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        let file = try XCTUnwrap(
            store.addBatch(
                count: 1,
                candidates: [Layer1AudioCandidate(url: audio, date: Date(), duration: 20)]
            )?.fileIDs.first)
        let modelA = Layer1ModelSpec.catalog[0].id
        let modelB = Layer1ModelSpec.catalog[1].id
        let timedAll = [
            Layer1WordTimestamp(word: "один", start: 0.1, end: 0.4),
            Layer1WordTimestamp(word: "два", start: 0.5, end: 0.8),
            Layer1WordTimestamp(word: "три", start: 0.9, end: 1.2),
            Layer1WordTimestamp(word: "четыре", start: 6.0, end: 6.4),
            Layer1WordTimestamp(word: "пять", start: 6.5, end: 6.8),
            Layer1WordTimestamp(word: "шесть", start: 6.9, end: 7.2),
        ]
        let timedPartial = [
            Layer1WordTimestamp(word: "один", start: 0.1, end: 0.4),
            Layer1WordTimestamp(word: "два", start: 0.5, end: 0.8),
            Layer1WordTimestamp(word: "три", start: 0.9, end: 1.2),
        ]
        for run in store.queuedRuns() {
            store.markRunning(run.id, configuration: run.configuration, version: "test", at: Date())
            let timestamps = run.modelID == modelB ? timedPartial : timedAll
            let text = run.modelID == modelB ? "один два три" : "один два три четыре пять шесть"
            store.finish(
                run.id,
                completion: .init(
                    status: .completed, version: "test", rawResponse: "{}",
                    text: text, timestamps: timestamps, error: nil, duration: 0.1))
        }
        let segments = store.state.segments.filter { $0.audioID == file }
        let early = segments.first { $0.start < 2.0 }
        let late = segments.first { $0.start >= 2.0 }
        XCTAssertEqual(early?.modelSuggestions[modelA]?.text, "один два три")
        XCTAssertEqual(early?.modelSuggestions[modelB]?.text, "один два три")
        XCTAssertEqual(late?.modelSuggestions[modelA]?.text, "четыре пять шесть")
        XCTAssertEqual(late?.modelSuggestions[modelB]?.text, "")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

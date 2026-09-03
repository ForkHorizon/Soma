import XCTest

@testable import Soma

final class Layer1GroundTruthSegmentationTests: XCTestCase {
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
            Layer1WordTimestamp(word: "Один,", start: 0.1, end: 0.4),
            Layer1WordTimestamp(word: "два", start: 0.5, end: 0.8),
            Layer1WordTimestamp(word: "три", start: 0.9, end: 1.2),
            Layer1WordTimestamp(word: "четыре", start: 6.0, end: 6.4),
            Layer1WordTimestamp(word: "пять", start: 6.5, end: 6.8),
            Layer1WordTimestamp(word: "шесть", start: 6.9, end: 7.2),
        ]
        let timedPartial = [
            Layer1WordTimestamp(word: "Один,", start: 0.1, end: 0.4),
            Layer1WordTimestamp(word: "два", start: 0.5, end: 0.8),
            Layer1WordTimestamp(word: "три", start: 0.9, end: 1.2),
        ]
        for run in store.queuedRuns() {
            store.markRunning(run.id, configuration: run.configuration, version: "test", at: Date())
            let timestamps = run.modelID == modelA ? timedAll : run.modelID == modelB ? timedPartial : []
            let text = run.modelID == modelB ? "Один, два три" : "Один, два три четыре пять шесть"
            store.finish(
                run.id,
                completion: .init(
                    status: .completed, version: "test", rawResponse: "{}",
                    text: text, timestamps: timestamps, error: nil, duration: 0.1))
        }
        let segments = store.state.segments.filter { $0.audioID == file }
        let early = segments.first { $0.start < 2.0 }
        let late = segments.first { $0.start >= 2.0 }
        XCTAssertEqual(early?.modelSuggestions[modelA]?.text, "Один, два три")
        XCTAssertEqual(early?.modelSuggestions[modelA]?.reviewText, "один два три")
        XCTAssertEqual(early?.modelSuggestions[modelB]?.text, "Один, два три")
        XCTAssertEqual(early?.modelSuggestions[modelB]?.reviewText, "один два три")
        XCTAssertEqual(late?.modelSuggestions[modelA]?.text, "четыре пять шесть")
        XCTAssertEqual(late?.modelSuggestions[modelB]?.text, "")
        XCTAssertNil(early?.modelSuggestions[Layer1ModelSpec.catalog[2].id])
        XCTAssertEqual(
            store.state.modelRuns.first { $0.modelID == Layer1ModelSpec.catalog[2].id }?.text,
            "Один, два три четыре пять шесть")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

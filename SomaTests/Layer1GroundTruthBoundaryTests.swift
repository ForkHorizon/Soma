import XCTest

@testable import Soma

final class Layer1GroundTruthBoundaryTests: XCTestCase {
    func testFlaggedSegmentIsRemovedFromHumanGoldAndCanBeCleared() throws {
        let root = try makeTempDirectory()
        let audio = root.appendingPathComponent("speech.wav")
        try Data("speech".utf8).write(to: audio)
        let store = Layer1GroundTruthStore(directory: root.appendingPathComponent("store"))
        store.state.files = [
            Layer1AudioFile(
                id: audio.path, path: audio.path,
                audioHash: Layer1GroundTruthStore.sha256(file: audio), duration: 1,
                addedAt: Date(), batchIDs: [], lastStatus: .queued)
        ]
        store.state.segments = [
            Layer1Segment(
                id: "segment", audioID: audio.path, start: 0, end: 1,
                segmentationAlgorithmVersion: "v1", sourceWordRange: nil,
                modelSuggestions: [:], proposalOrder: [], segmentationNeedsReview: false,
                decision: .init(
                    status: .pending, text: nil, normalizedText: nil, action: nil,
                    sourceModelID: nil, createdAt: nil, updatedAt: nil))
        ]

        store.saveDecision(segmentID: "segment", text: "Текст,  это.", action: .manual)
        let goldURL = root.appendingPathComponent("human/gold.jsonl")
        let initialGold = try String(contentsOf: goldURL, encoding: .utf8)
        XCTAssertTrue(initialGold.contains("текст это"))
        XCTAssertFalse(initialGold.contains("Текст,  это."))

        store.markSegmentationNeedsReview("segment")

        XCTAssertEqual(try String(contentsOf: goldURL, encoding: .utf8), "")
        store.clearSegmentationNeedsReview("segment")
        XCTAssertTrue(store.fullyVerifiedFileIDs().contains(audio.path))
        XCTAssertTrue(try String(contentsOf: goldURL, encoding: .utf8).contains("текст это"))
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

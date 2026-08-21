import XCTest
@testable import Soma

@MainActor
final class VoicePauseDetectorTests: XCTestCase {
    private let sampleRate = 16_000.0
    private let frameCount = 160  // 10 ms

    private func startSpeech(_ detector: VoicePauseDetector) {
        assertNone(detector.observe(dbfs: -20, frames: frameCount))
        guard case .speechStarted = detector.observe(dbfs: -20, frames: frameCount) else {
            return XCTFail("second speech buffer must begin a phrase")
        }
    }

    private func assertNone(_ event: VoicePauseEvent, file: StaticString = #filePath, line: UInt = #line) {
        guard case .none = event else {
            XCTFail("expected no boundary, got \(event)", file: file, line: line)
            return
        }
    }

    func testSilenceNeverStartsOrClosesAChunk() {
        let detector = VoicePauseDetector(sampleRate: sampleRate)
        for _ in 0..<400 {
            assertNone(detector.observe(dbfs: -75, frames: frameCount))
        }
        XCTAssertFalse(detector.hasEnoughFinalSpeech)
    }

    func testShortPauseStaysWithinTheSamePhrase() {
        let detector = VoicePauseDetector(sampleRate: sampleRate)
        startSpeech(detector)

        for _ in 0..<100 { assertNone(detector.observe(dbfs: -20, frames: frameCount)) }
        for _ in 0..<65 { assertNone(detector.observe(dbfs: -75, frames: frameCount)) }

        for _ in 0..<100 { assertNone(detector.observe(dbfs: -20, frames: frameCount)) }
        for _ in 0..<64 { assertNone(detector.observe(dbfs: -75, frames: frameCount)) }
        guard case .pauseBoundary = detector.observe(dbfs: -75, frames: frameCount) else {
            return XCTFail("an eligible 650 ms pause must close the phrase")
        }
    }

    func testEligiblePauseClosesAt650Milliseconds() {
        let detector = VoicePauseDetector(sampleRate: sampleRate)
        startSpeech(detector)

        for _ in 0..<250 { assertNone(detector.observe(dbfs: -20, frames: frameCount)) }
        for _ in 0..<64 { assertNone(detector.observe(dbfs: -75, frames: frameCount)) }
        guard case .pauseBoundary = detector.observe(dbfs: -75, frames: frameCount) else {
            return XCTFail("650 ms of silence should produce a natural boundary")
        }
    }

    func testContinuousSpeechForcesA10SecondBoundary() {
        let detector = VoicePauseDetector(sampleRate: sampleRate)
        startSpeech(detector)

        for _ in 0..<9 {
            assertNone(detector.observe(dbfs: -20, frames: Int(sampleRate)))
        }
        guard case .forcedBoundary = detector.observe(dbfs: -20, frames: Int(sampleRate)) else {
            return XCTFail("continuous speech must force a 10 second boundary")
        }
    }

    func testForcedOverlapRequiresFreshSpeechForAFinalTail() {
        let detector = VoicePauseDetector(sampleRate: sampleRate)
        detector.beginForcedOverlap()
        XCTAssertFalse(detector.hasEnoughFinalSpeech)
        for _ in 0..<25 { assertNone(detector.observe(dbfs: -20, frames: frameCount)) }
        XCTAssertTrue(detector.hasEnoughFinalSpeech)
        detector.reset()
        XCTAssertFalse(detector.hasEnoughFinalSpeech)
    }
}

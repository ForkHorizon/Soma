import XCTest
@testable import Soma

@MainActor
final class MediaImportTests: XCTestCase {
    func testChunkMathKeepsBoundedOverlap() {
        XCTAssertEqual(MediaImportTools.chunkCount(for: 1), 1)
        XCTAssertEqual(MediaImportTools.chunkCount(for: 60), 1)
        XCTAssertEqual(MediaImportTools.chunkCount(for: 61), 2)
        XCTAssertEqual(MediaImportTools.chunkStart(index: 1), 58, accuracy: 0.001)
        XCTAssertEqual(MediaImportTools.chunkStart(index: 30), 1_740, accuracy: 0.001)
    }

    func testPauseAwarePlanUsesNearbySilenceAndKeepsForcedOverlapAsFallback() {
        let chunks = MediaImportTools.planChunks(duration: 180, silenceEnds: [58, 121])
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(chunks[1].startSeconds, 58, accuracy: 0.001)
        XCTAssertEqual(chunks[2].startSeconds, 121, accuracy: 0.001)
        XCTAssertEqual(chunks.map(\.reason), ["pause", "pause", "pause"])

        let fallback = MediaImportTools.planChunks(duration: 130, silenceEnds: [])
        XCTAssertEqual(fallback[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(fallback[0].durationSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(fallback[0].overlapSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(fallback[1].startSeconds, 58, accuracy: 0.001)
    }

    func testMergeRemovesWordOverlap() {
        XCTAssertEqual(
            MediaImportTools.mergedText("one two three four", with: "three four five"),
            "one two three four five"
        )
    }

    func testRepetitionGuardFlagsDecoderLoops() {
        XCTAssertFalse(MediaImportTools.hasPathologicalRepetition("yes yes yes yes"))
        XCTAssertTrue(MediaImportTools.hasPathologicalRepetition(String(repeating: "already ", count: 12)))
        XCTAssertTrue(MediaImportTools.hasPathologicalRepetition(String(repeating: "come back here for a second ", count: 3)))
        XCTAssertTrue(MediaImportTools.hasPathologicalRepetition(String(repeating: "f sağ ", count: 6)))
        XCTAssertTrue(MediaImportTools.hasPathologicalRepetition(String(repeating: "... ", count: 8)))
    }

    func testContextTranscriptIsRemovedAfterRecovery() {
        XCTAssertEqual(
            MediaImportTools.removingContextPrefix("previous clip", from: "previous clip recovered current clip"),
            "recovered current clip"
        )
        XCTAssertNil(MediaImportTools.removingContextPrefix("previous clip", from: "different audio"))
    }

    func testJobPersistsOnlyMetadataAndSourcePath() throws {
        let source = URL(fileURLWithPath: "/tmp/movie.mkv")
        let job = MediaImportJob(sourceURL: source, backend: "remote", engine: "whisper", remoteURL: "https://m1.example.ts.net")
        let restored = try JSONDecoder().decode(MediaImportJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(restored.sourcePath, source.path)
        XCTAssertEqual(restored.nextChunkIndex, 0)
        XCTAssertNil(restored.sessionID)
        XCTAssertFalse(String(data: try JSONEncoder().encode(job), encoding: .utf8)?.contains("audioBytes") ?? true)
    }

    func testInterruptedJobReturnsToQueueAfterRelaunch() {
        var job = MediaImportJob(
            sourceURL: URL(fileURLWithPath: "/tmp/movie.mkv"),
            backend: "remote",
            engine: "whisper",
            remoteURL: "https://m1.example.ts.net"
        )
        job.phase = .uploading
        job.nextChunkIndex = 7
        job.sessionID = "persisted-session"

        job.prepareToResumeAfterRelaunch()

        XCTAssertEqual(job.phase, .queued)
        XCTAssertEqual(job.nextChunkIndex, 7)
        XCTAssertEqual(job.sessionID, "persisted-session")
    }

    func testFailureStillRequiresExplicitRetryAfterRelaunch() {
        var job = MediaImportJob(
            sourceURL: URL(fileURLWithPath: "/tmp/movie.mkv"),
            backend: "remote",
            engine: "whisper",
            remoteURL: "https://m1.example.ts.net"
        )
        job.phase = .failed
        job.prepareToResumeAfterRelaunch()
        XCTAssertEqual(job.phase, .failed)
    }

    func testRetryDropsPartialFragmentsAndProgress() {
        var job = MediaImportJob(
            sourceURL: URL(fileURLWithPath: "/tmp/movie.mkv"),
            backend: "local",
            engine: "whisper",
            remoteURL: nil
        )
        job.nextChunkIndex = 7
        job.sessionID = "stale-session"
        job.retryCount = 2
        job.errorMessage = "failed"
        job.localFragments = ["stale transcript"]

        job.prepareForRetry()

        XCTAssertEqual(job.nextChunkIndex, 0)
        XCTAssertNil(job.sessionID)
        XCTAssertEqual(job.retryCount, 0)
        XCTAssertNil(job.errorMessage)
        XCTAssertTrue(job.localFragments.isEmpty)
    }
}

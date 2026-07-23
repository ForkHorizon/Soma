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

    func testMergeRemovesWordOverlap() {
        XCTAssertEqual(
            MediaImportTools.mergedText("one two three four", with: "three four five"),
            "one two three four five"
        )
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
}

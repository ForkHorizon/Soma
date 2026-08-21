import XCTest
@testable import Soma

/// Intercepts URLSession.shared so record-start ordering can be observed and
/// individual endpoints can be delayed or failed on demand.
final class StubVoiceServer: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [String] = []
    nonisolated(unsafe) private static var delays: [String: TimeInterval] = [:]
    nonisolated(unsafe) private static var failing: Set<String> = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        recorded = []
        delays = [:]
        failing = []
    }

    static func delay(_ path: String, _ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        delays[path] = seconds
    }

    static func fail(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        failing.insert(path)
    }

    static var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func count(_ path: String) -> Int {
        paths.filter { $0 == path }.count
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.recorded.append(path)
        let delay = Self.delays[path] ?? 0
        let shouldFail = Self.failing.contains(path)
        Self.lock.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if shouldFail {
                self.client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            let (status, body) = Self.response(for: path)
            let response = HTTPURLResponse(
                url: self.request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func response(for path: String) -> (Int, String) {
        if path.hasSuffix("/v1/health") {
            return (200, #"{"version":2,"capabilities":["warmup","chunk_sessions","long_poll","flac","final_chunk_finalize"]}"#)
        }
        if path.hasSuffix("/v1/warmup") {
            return (200, #"{"already_loaded":true,"load_seconds":0}"#)
        }
        if path.hasSuffix("/v1/sessions") {
            return (201, #"{"session_id":"stub-session","status":"recording"}"#)
        }
        // Chunk uploads live under /v1/sessions/{id}/chunks/{n}, so they must be
        // matched before the session-status branch below.
        if path.contains("/chunks/") {
            return (202, #"{"job_id":"stub-job","status":"queued"}"#)
        }
        if path.contains("/v1/sessions/") {
            return (200, #"{"session_id":"stub-session","status":"recording","completed_chunks":1,"partial_text":"первая фраза"}"#)
        }
        return (200, #"{"status":"recording"}"#)
    }
}

@MainActor
final class VoiceChunkPipelineStartTests: XCTestCase {
    private let base = URL(string: "https://stub.invalid")!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubVoiceServer.self)
        StubVoiceServer.reset()
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubVoiceServer.self)
        StubVoiceServer.reset()
        super.tearDown()
    }

    private func makePipeline(
        onCapabilities: (@Sendable (VoiceServerHealth?) -> Void)? = nil,
        onPartialTranscript: (@Sendable (String) -> Void)? = nil
    ) -> VoiceChunkPipeline {
        VoiceChunkPipeline(
            base: base, token: "t", clientID: "c", engine: "whisper",
            idleSeconds: 600, workClass: .interactive, capabilityHint: nil,
            onCapabilities: onCapabilities, onPartialTranscript: onPartialTranscript
        )
    }

    func testDecodedTextIsDeliveredWhileTheSessionIsStillRecording() async {
        let delivered = expectation(description: "partial transcript delivered")
        let seen = UncheckedBox<String>("")
        let pipeline = makePipeline(onPartialTranscript: { text in
            guard seen.value.isEmpty else { return }
            seen.value = text
            delivered.fulfill()
        })
        await pipeline.start()
        await fulfillment(of: [delivered], timeout: 5)
        // The session never reached "done"; this is text arriving mid-recording.
        XCTAssertEqual(seen.value, "первая фраза")
        await pipeline.cancel()
    }

    /// Warmup and session creation are concurrent, so their network order is not
    /// deterministic; poll rather than assume one lands first.
    private func awaitRequest(_ path: String, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if StubVoiceServer.count(path) >= 1 { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    func testRecordStartDoesNotWaitForHealth() async {
        StubVoiceServer.delay("/v1/health", 1.5)
        let started = Date()
        await makePipeline().start()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.8, "record start waited on the health probe")
        XCTAssertEqual(StubVoiceServer.count("/v1/sessions"), 1, "the session must be created anyway")
        let warmed = await awaitRequest("/v1/warmup")
        XCTAssertTrue(warmed, "warmup must be fired at record start")
    }

    func testWarmupIsNotGatedOnSessionCreation() async {
        // A failed session falls back to whole-file transcription on the same
        // engine, so the model still needs to be warming.
        StubVoiceServer.fail("/v1/sessions")
        await makePipeline().start()

        let warmed = await awaitRequest("/v1/warmup")
        XCTAssertTrue(warmed, "warmup must survive a failed session create")
    }

    func testHealthIsProbedOnlyOncePerRecording() async {
        let pipeline = makePipeline()
        await pipeline.start()
        // finalize() resolves the same in-flight probe rather than re-asking.
        _ = try? await pipeline.finalize(expectedChunkCount: 0)
        XCTAssertEqual(StubVoiceServer.count("/v1/health"), 1, "record start must issue exactly one health probe")
    }

    func testUnreachableHealthDoesNotAbortAWorkingSession() async {
        StubVoiceServer.fail("/v1/health")
        let reported = expectation(description: "capabilities reported")
        let seen = UncheckedBox<VoiceServerHealth?>(nil)
        let pipeline = makePipeline { health in
            seen.value = health
            reported.fulfill()
        }
        await pipeline.start()

        // A chunk still uploads: the probe failing is not the server saying no.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stub-chunk.flac")
        try? Data("audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await pipeline.enqueue(VoiceChunk(
            index: 0, url: url, reason: .final,
            overlapMilliseconds: 0, durationMilliseconds: 500
        ))

        await fulfillment(of: [reported], timeout: 5)
        XCTAssertNil(seen.value, "an unreachable probe reports nil, not a capability set")
        XCTAssertEqual(StubVoiceServer.count("/v1/sessions"), 1)
        XCTAssertEqual(StubVoiceServer.paths.filter { $0.contains("/chunks/") }.count, 1,
                       "the chunk must still upload when only the health probe failed")
    }
}

/// Minimal mutable box for capturing a value out of a @Sendable callback.
final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

import AVFoundation
import Foundation

enum VoiceChunkReason: String, Sendable {
    case pause
    case forced
    case final
}

/// Interactive dictation always runs before queued media imports. A currently
/// running MLX inference is deliberately never interrupted.
enum VoiceWorkClass: String, Codable, Sendable {
    case interactive
    case background
}

struct VoiceChunk: Sendable {
    let index: Int
    let url: URL
    let reason: VoiceChunkReason
    let overlapMilliseconds: Int
    let durationMilliseconds: Int

    var contentType: String {
        url.pathExtension.lowercased() == "flac" ? "audio/flac" : "audio/wav"
    }
}

enum VoicePauseEvent {
    case none
    case speechStarted
    case pauseBoundary
    case forcedBoundary
}

/// Lightweight energy-based VAD. It deliberately runs on the serial audio queue,
/// never in AVAudioEngine's real-time tap callback.
final class VoicePauseDetector {
    private let sampleRate: Double
    private var noiseFloorDB: Double = -60
    private var speechBuffers = 0
    private var active = false
    private var activeFrames = 0
    private var speechFrames = 0
    private var silenceFrames = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    func observe(dbfs: Double, frames: Int) -> VoicePauseEvent {
        let threshold = min(-30, max(-48, noiseFloorDB + 12))
        let speech = dbfs >= threshold
        if !active {
            if speech {
                speechBuffers += 1
                if speechBuffers >= 2 {
                    active = true
                    activeFrames = frames * speechBuffers
                    speechFrames = activeFrames
                    silenceFrames = 0
                    return .speechStarted
                }
            } else {
                speechBuffers = 0
                noiseFloorDB = max(-80, min(-20, noiseFloorDB * 0.95 + dbfs * 0.05))
            }
            return .none
        }

        activeFrames += frames
        if speech {
            speechFrames += frames
            silenceFrames = 0
        } else {
            silenceFrames += frames
        }
        if activeFrames >= Int(sampleRate * 10) {
            reset()
            return .forcedBoundary
        }
        if activeFrames >= Int(sampleRate * 2.5), silenceFrames >= Int(sampleRate * 0.65) {
            reset()
            return .pauseBoundary
        }
        return .none
    }

    var hasEnoughFinalSpeech: Bool {
        active && speechFrames >= Int(sampleRate * 0.25)
    }

    func beginForcedOverlap() {
        active = true
        speechBuffers = 2
        activeFrames = Int(sampleRate * 0.75)
        // The replayed overlap is context, not newly detected speech. A final
        // tail must still contain at least 250 ms of fresh speech.
        speechFrames = 0
        silenceFrames = 0
    }

    func reset() {
        speechBuffers = 0
        active = false
        activeFrames = 0
        speechFrames = 0
        silenceFrames = 0
    }
}

/// Splits the existing converted 16 kHz PCM stream into short transport files while
/// retaining the complete recording in ASRManager for history and fallback.
final class VoiceChunkCapture {
    private struct BufferedAudio {
        let buffer: AVAudioPCMBuffer
        let seconds: Double
    }

    private let settings: [String: Any]
    private let fileExtension: String
    private let directory: URL
    private let onChunk: (VoiceChunk) -> Void
    private var detector: VoicePauseDetector?
    private var ring: [BufferedAudio] = []
    private var ringSeconds = 0.0
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var writtenFrames = 0
    private var nextIndex = 0
    private var reason: VoiceChunkReason = .pause
    private var overlapMilliseconds = 0

    init(settings: [String: Any], fileExtension: String = "wav", onChunk: @escaping (VoiceChunk) -> Void) {
        self.settings = settings
        self.fileExtension = fileExtension
        self.onChunk = onChunk
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-voice-chunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        if detector == nil {
            detector = VoicePauseDetector(sampleRate: buffer.format.sampleRate)
        }
        remember(buffer)
        let event = detector?.observe(dbfs: levelDBFS(buffer), frames: Int(buffer.frameLength)) ?? .none
        var wroteCurrentThroughReplay = false
        if case .speechStarted = event {
            startChunk(replaySeconds: 0.25, reason: .pause, overlapMilliseconds: 0)
            wroteCurrentThroughReplay = true
        }
        if file != nil && !wroteCurrentThroughReplay {
            write(buffer)
        }
        switch event {
        case .pauseBoundary:
            seal(reason: .pause)
        case .forcedBoundary:
            seal(reason: .forced)
            startChunk(replaySeconds: 0.75, reason: .forced, overlapMilliseconds: 750)
            detector?.beginForcedOverlap()
        case .none, .speechStarted:
            break
        }
    }

    func finish() -> Int {
        if detector?.hasEnoughFinalSpeech == true {
            seal(reason: .final)
        } else {
            discardOpenChunk()
        }
        detector?.reset()
        return nextIndex
    }

    func cancel() {
        discardOpenChunk()
        detector?.reset()
        ring.removeAll()
        ringSeconds = 0
    }

    private func startChunk(replaySeconds: Double, reason: VoiceChunkReason, overlapMilliseconds: Int) {
        guard file == nil else { return }
        let url = directory.appendingPathComponent("chunk-\(UUID().uuidString).\(fileExtension)")
        do {
            file = try AVAudioFile(forWriting: url, settings: settings)
            fileURL = url
            writtenFrames = 0
            self.reason = reason
            self.overlapMilliseconds = overlapMilliseconds
            for retained in buffersForLast(replaySeconds) {
                write(retained)
            }
        } catch {
            file = nil
            fileURL = nil
        }
    }

    private func seal(reason: VoiceChunkReason) {
        guard let url = fileURL, file != nil, writtenFrames > 0 else {
            discardOpenChunk()
            return
        }
        file = nil
        fileURL = nil
        let sampleRate = settings[AVSampleRateKey] as? Double ?? 16_000
        let durationMilliseconds = Int((Double(writtenFrames) / sampleRate * 1_000).rounded())
        let chunk = VoiceChunk(
            index: nextIndex,
            url: url,
            reason: reason == .pause ? self.reason : reason,
            overlapMilliseconds: self.overlapMilliseconds,
            durationMilliseconds: durationMilliseconds
        )
        nextIndex += 1
        onChunk(chunk)
    }

    private func discardOpenChunk() {
        file = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        writtenFrames = 0
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let file else { return }
        try? file.write(from: buffer)
        writtenFrames += Int(buffer.frameLength)
    }

    private func remember(_ buffer: AVAudioPCMBuffer) {
        guard let copy = copied(buffer) else { return }
        let seconds = Double(copy.frameLength) / copy.format.sampleRate
        ring.append(BufferedAudio(buffer: copy, seconds: seconds))
        ringSeconds += seconds
        while ringSeconds > 0.9, let removed = ring.first {
            ring.removeFirst()
            ringSeconds -= removed.seconds
        }
    }

    private func buffersForLast(_ seconds: Double) -> [AVAudioPCMBuffer] {
        var remaining = seconds
        var selected: [AVAudioPCMBuffer] = []
        for retained in ring.reversed() {
            selected.append(retained.buffer)
            remaining -= retained.seconds
            if remaining <= 0 { break }
        }
        return selected.reversed()
    }

    private func levelDBFS(_ buffer: AVAudioPCMBuffer) -> Double {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return -80 }
        var sum = 0.0
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<count {
                let value = Double(samples[index])
                sum += value * value
            }
        } else if let samples = buffer.int16ChannelData?[0] {
            for index in 0..<count {
                let value = Double(samples[index]) / Double(Int16.max)
                sum += value * value
            }
        } else {
            return -80
        }
        return max(-80, 20 * log10(max(sqrt(sum / Double(count)), 0.000_000_1)))
    }

    private func copied(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let frames = Int(source.frameLength)
        let channels = Int(source.format.channelCount)
        if let sourceData = source.floatChannelData, let copyData = copy.floatChannelData {
            for channel in 0..<channels {
                copyData[channel].update(from: sourceData[channel], count: frames)
            }
            return copy
        }
        if let sourceData = source.int16ChannelData, let copyData = copy.int16ChannelData {
            for channel in 0..<channels {
                copyData[channel].update(from: sourceData[channel], count: frames)
            }
            return copy
        }
        return nil
    }
}

enum VoiceChunkPipelineError: LocalizedError {
    case unsupported
    case missingSession
    case missingChunk(Int)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: "Soma Voice Server does not support chunk sessions."
        case .missingSession: "Voice session was not created."
        case .missingChunk(let index): "Voice chunk \(index) was not uploaded."
        case .server(let message): message
        }
    }
}

struct VoiceChunkPipelineResult: Sendable {
    let text: String
    let mergeSafe: Bool
    let inferSeconds: Double?
}

nonisolated struct VoiceServerHealth: Decodable, Sendable {
    let version: Int?
    let capabilities: [String]?
}

nonisolated struct VoiceServerWarmupResponse: Decodable, Sendable {
    let already_loaded: Bool?
    let load_seconds: Double?
}

nonisolated struct VoiceServerSessionResponse: Decodable, Sendable {
    let session_id: String?
    let status: String?
    let text: String?
    let merge_safe: Bool?
    let accepted_chunks: Int?
    let completed_chunks: Int?
    let metrics: VoiceServerSessionMetrics?
    let error: VoiceServerPipelineError?
}

nonisolated struct VoiceServerSessionMetrics: Decodable, Sendable {
    let queued_seconds: Double?
    let infer_seconds: Double?
    let duration_milliseconds: Int?
}

nonisolated struct VoiceServerPipelineError: Decodable, Sendable {
    let message: String?
}

/// Emits timing-only, privacy-preserving diagnostics. Transcript text and audio
/// never appear in these events.
nonisolated enum VoiceMetrics {
    static func log(_ event: String, _ fields: [String: String] = [:]) {
        var payload = fields
        payload["event"] = event
        payload["timestamp_milliseconds"] = "\(Int(Date().timeIntervalSince1970 * 1_000))"
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return }
        print("[soma.voice] \(text)")
    }
}

/// Serializes session creation and file-backed uploads. Recording can continue
/// while this actor uploads and the server decodes completed phrase chunks.
actor VoiceChunkPipeline {
    private let base: URL
    private let token: String
    private let clientID: String
    private let engine: String
    private let idleSeconds: Int
    private let workClass: VoiceWorkClass
    private let capabilityHint: Bool?
    private let sessionRequestID = UUID().uuidString
    private var sessionID: String?
    private var started = false
    private var cancelled = false
    private var warmupTask: Task<Void, Never>?
    private var pending: [Int: VoiceChunk] = [:]
    private var uploaded: Set<Int> = []
    private var failure: Error?
    private var allChunkURLs: [URL] = []
    private var sentFinalChunk = false
    private var supportsFinalChunkFinalize = false

    init(
        base: URL,
        token: String,
        clientID: String,
        engine: String,
        idleSeconds: Int,
        workClass: VoiceWorkClass = .interactive,
        capabilityHint: Bool? = nil
    ) {
        self.base = base
        self.token = token
        self.clientID = clientID
        self.engine = engine
        self.idleSeconds = idleSeconds
        self.workClass = workClass
        self.capabilityHint = capabilityHint
    }

    func start() async {
        guard !started, !cancelled else { return }
        started = true
        do {
            guard capabilityHint != false else { throw VoiceChunkPipelineError.unsupported }
            // Fetch capabilities for every new recording. This happens while
            // recording, lets rolling M1 upgrades take effect immediately, and
            // avoids guessing whether final-chunk finalization is available.
            let health = try await requestHealth()
            let capabilities = Set(health.capabilities ?? [])
            guard (health.version ?? 0) >= 2, capabilities.isSuperset(of: ["warmup", "chunk_sessions", "long_poll"]) else {
                throw VoiceChunkPipelineError.unsupported
            }
            supportsFinalChunkFinalize = capabilities.contains("final_chunk_finalize")
            guard !cancelled else { return }
            warmupTask = Task { [base, token, clientID, engine, idleSeconds] in
                let warmStartedAt = Date()
                do {
                    let result = try await Self.warm(
                        base: base,
                        token: token,
                        clientID: clientID,
                        engine: engine,
                        idleSeconds: idleSeconds
                    )
                    VoiceMetrics.log("warmup_finished", [
                        "engine": engine,
                        "already_loaded": "\(result.already_loaded ?? false)",
                        "load_seconds": "\(result.load_seconds ?? 0)",
                        "request_milliseconds": "\(Int(Date().timeIntervalSince(warmStartedAt) * 1_000))",
                    ])
                } catch {
                    VoiceMetrics.log("warmup_failed", [
                        "engine": engine,
                        "request_milliseconds": "\(Int(Date().timeIntervalSince(warmStartedAt) * 1_000))",
                    ])
                }
            }
            let createdSessionID = try await createSession()
            guard !cancelled else {
                await deleteSession(createdSessionID)
                return
            }
            sessionID = createdSessionID
            await drain()
            if !cancelled {
                log("session_started", ["session_id": sessionID ?? ""])
            }
        } catch {
            if !cancelled {
                failure = error
                log("session_unavailable", ["error": error.localizedDescription])
            }
        }
    }

    func enqueue(_ chunk: VoiceChunk) async {
        guard !cancelled else {
            try? FileManager.default.removeItem(at: chunk.url)
            return
        }
        allChunkURLs.append(chunk.url)
        pending[chunk.index] = chunk
        await drain()
    }

    func finalize(expectedChunkCount: Int) async throws -> VoiceChunkPipelineResult {
        if !started { await start() }
        let releasedAt = Date()
        log("recording_released", [
            "expected_chunks": "\(expectedChunkCount)",
            "acknowledged_chunks": "\(uploaded.count)",
            "pending_chunks": "\(max(0, expectedChunkCount - uploaded.count))",
        ])
        let deadline = Date().addingTimeInterval(90)
        while uploaded.count < expectedChunkCount && failure == nil && Date() < deadline {
            await drain()
            if uploaded.count < expectedChunkCount {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        if let failure { cleanup(); throw failure }
        guard uploaded.count == expectedChunkCount else {
            cleanup()
            throw VoiceChunkPipelineError.missingChunk(uploaded.count)
        }
        guard let sessionID else {
            cleanup()
            throw VoiceChunkPipelineError.missingSession
        }
        do {
            if !supportsFinalChunkFinalize || !sentFinalChunk {
                try await finalizeSession(sessionID)
            }
            let response = try await waitForFinalSession(sessionID)
            guard response.status == "done" else {
                throw VoiceChunkPipelineError.server(response.error?.message ?? "Voice session did not finish.")
            }
            let result = VoiceChunkPipelineResult(
                text: response.text ?? "",
                mergeSafe: response.merge_safe ?? false,
                inferSeconds: response.metrics?.infer_seconds
            )
            log("session_done", [
                "accepted_chunks": "\(response.accepted_chunks ?? 0)",
                "completed_chunks": "\(response.completed_chunks ?? 0)",
                "queued_seconds": "\(response.metrics?.queued_seconds ?? 0)",
                "infer_seconds": "\(response.metrics?.infer_seconds ?? 0)",
                "duration_milliseconds": "\(response.metrics?.duration_milliseconds ?? 0)",
                "release_to_final_milliseconds": "\(Int(Date().timeIntervalSince(releasedAt) * 1_000))",
            ])
            cleanup()
            return result
        } catch {
            cleanup()
            throw error
        }
    }

    func cancel() async {
        guard !cancelled else { return }
        cancelled = true
        warmupTask?.cancel()
        warmupTask = nil
        let activeSessionID = sessionID
        sessionID = nil
        cleanup()
        if let activeSessionID {
            await deleteSession(activeSessionID)
        }
    }

    private func drain() async {
        guard failure == nil, let sessionID else { return }
        while let next = pending.keys.sorted().first(where: { !uploaded.contains($0) }), let chunk = pending[next] {
            do {
                let uploadStartedAt = Date()
                try await upload(chunk, to: sessionID)
                uploaded.insert(next)
                sentFinalChunk = sentFinalChunk || chunk.reason == .final
                log("chunk_uploaded", [
                    "index": "\(next)",
                    "reason": chunk.reason.rawValue,
                    "duration_milliseconds": "\(chunk.durationMilliseconds)",
                    "upload_milliseconds": "\(Int(Date().timeIntervalSince(uploadStartedAt) * 1_000))",
                ])
            } catch {
                failure = error
                return
            }
        }
    }

    private func requestHealth() async throws -> VoiceServerHealth {
        var request = request(base.appendingPathComponent("v1/health"))
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw VoiceChunkPipelineError.unsupported }
        return try JSONDecoder().decode(VoiceServerHealth.self, from: data)
    }

    private func createSession() async throws -> String {
        var request = request(base.appendingPathComponent("v1/sessions"))
        request.httpMethod = "POST"
        request.setValue(sessionRequestID, forHTTPHeaderField: "X-Soma-Request-ID")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (code == 200 || code == 201), let session = try? JSONDecoder().decode(VoiceServerSessionResponse.self, from: data), let sessionID = session.session_id else {
            throw VoiceChunkPipelineError.server(remoteErrorMessage(data, fallback: "Could not create voice session."))
        }
        return sessionID
    }

    private func upload(_ chunk: VoiceChunk, to sessionID: String) async throws {
        var lastError: Error?
        for _ in 0..<3 {
            do {
                var request = request(base.appendingPathComponent("v1/sessions/\(sessionID)/chunks/\(chunk.index)"))
                request.httpMethod = "PUT"
                request.setValue(chunk.contentType, forHTTPHeaderField: "Content-Type")
                request.setValue(workClass.rawValue, forHTTPHeaderField: "X-Soma-Work-Class")
                request.setValue("\(sessionID)-\(chunk.index)", forHTTPHeaderField: "X-Soma-Request-ID")
                request.setValue(chunk.reason.rawValue, forHTTPHeaderField: "X-Soma-Chunk-Reason")
                if supportsFinalChunkFinalize, chunk.reason == .final {
                    request.setValue("1", forHTTPHeaderField: "X-Soma-Finalize-Session")
                }
                request.setValue("\(chunk.overlapMilliseconds)", forHTTPHeaderField: "X-Soma-Overlap-Milliseconds")
                request.setValue("\(chunk.durationMilliseconds)", forHTTPHeaderField: "X-Soma-Chunk-Duration-Milliseconds")
                request.timeoutInterval = 60
                let (data, response) = try await URLSession.shared.upload(for: request, fromFile: chunk.url)
                guard (response as? HTTPURLResponse)?.statusCode == 202 else {
                    throw VoiceChunkPipelineError.server(remoteErrorMessage(data, fallback: "Chunk upload failed."))
                }
                return
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
        throw lastError ?? VoiceChunkPipelineError.server("Chunk upload failed.")
    }

    private func finalizeSession(_ sessionID: String) async throws {
        var request = request(base.appendingPathComponent("v1/sessions/\(sessionID)/finalize"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw VoiceChunkPipelineError.server(remoteErrorMessage(data, fallback: "Could not finalize voice session."))
        }
    }

    private func deleteSession(_ sessionID: String) async {
        var request = request(base.appendingPathComponent("v1/sessions/\(sessionID)"))
        request.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: request)
    }

    private func waitForFinalSession(_ sessionID: String) async throws -> VoiceServerSessionResponse {
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            var components = URLComponents(url: base.appendingPathComponent("v1/sessions/\(sessionID)"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "wait", value: "25")]
            var request = request(components.url!)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let payload = try? JSONDecoder().decode(VoiceServerSessionResponse.self, from: data)
            else {
                throw VoiceChunkPipelineError.server(remoteErrorMessage(data, fallback: "Voice session polling failed."))
            }
            if payload.status == "done" || payload.status == "failed" || payload.status == "canceled" {
                return payload
            }
        }
        throw VoiceChunkPipelineError.server("Voice session timed out.")
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientID, forHTTPHeaderField: "X-Soma-Client-ID")
        request.setValue(engine, forHTTPHeaderField: "X-Soma-Engine")
        request.setValue("\(idleSeconds)", forHTTPHeaderField: "X-Soma-Idle-Seconds")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private static func warm(base: URL, token: String, clientID: String, engine: String, idleSeconds: Int) async throws -> VoiceServerWarmupResponse {
        var request = URLRequest(url: base.appendingPathComponent("v1/warmup"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientID, forHTTPHeaderField: "X-Soma-Client-ID")
        request.setValue(engine, forHTTPHeaderField: "X-Soma-Engine")
        request.setValue("\(idleSeconds)", forHTTPHeaderField: "X-Soma-Idle-Seconds")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 90
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw VoiceChunkPipelineError.server("Model warm-up failed.")
        }
        return try JSONDecoder().decode(VoiceServerWarmupResponse.self, from: data)
    }

    private func cleanup() {
        for url in allChunkURLs { try? FileManager.default.removeItem(at: url) }
        allChunkURLs.removeAll()
        pending.removeAll()
    }

    private func remoteErrorMessage(_ data: Data, fallback: String) -> String {
        (try? JSONDecoder().decode(VoiceServerSessionResponse.self, from: data).error?.message) ?? fallback
    }

    private func log(_ event: String, _ fields: [String: String]) {
        VoiceMetrics.log(event, fields)
    }
}

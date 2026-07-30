import AppKit
import AVFoundation
import Combine
import Foundation
import Network
import SwiftUI


private struct RecordingIndexEntry: Sendable {
    let url: URL
    let date: Date
    let hasTranscript: Bool
}

private struct QueuedTranscription {
    let url: URL
    let source: ASRTranscriptionSource
    let chunkPipeline: VoiceChunkPipeline?
    let expectedChunkCount: Int
    let continuation: CheckedContinuation<String?, Never>
}

private struct VoiceServerErrorEnvelope: Decodable {
    let error: VoiceServerErrorDetail?
}

private struct VoiceServerErrorDetail: Decodable {
    let code: String?
    let message: String?
    let retryable: Bool?
}

private struct VoiceServerRemoteError: LocalizedError {
    let code: String
    let message: String
    let retryable: Bool

    var errorDescription: String? { message }
}

private struct VoiceServerJobResponse: Decodable {
    let job_id: String?
    let status: String?
    let text: String?
    let infer_seconds: Double?
    let queued_seconds: Double?
    let error: VoiceServerErrorDetail?
}

/// Records mic audio and transcribes it via the warm multi-engine ASR server
/// (asr_server.py under the engines folder; engine = Whisper large-v3 or GigaAM v2).
/// The server is launched on first use and kept alive for the app session; it holds
/// the model in memory for `keepLoadedMinutes` of idle time so repeated
/// transcriptions skip the slow reload. Changing `engine` relaunches it.
final class ASRManager: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var transcript = ""
    @Published var status = "Idle"
    @Published var lastInferSeconds: Double?
    @Published var lastRecordingURL: URL?      // persisted; survives a failed transcription
    @Published var playingURL: URL?            // which recording is currently playing
    @Published var recordings: [VoiceRecording] = []
    @Published private(set) var recordingsTotal = 0
    @Published var completedTranscriptionID = 0   // bumped when a recording is FULLY transcribed (final)
    @Published var lastTranscriptionSource: ASRTranscriptionSource = .inApp
    @Published var voiceServerConnectionState: VoiceServerConnectionState = .unknown
    @Published var voiceServerStatusDetail = "Not checked"
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var importJobs: [MediaImportJob] = []
    @Published private(set) var importHistory: [MediaImportHistory] = []

    // Settings live in UserDefaults so the view's @AppStorage and this manager share them.
    // ponytail: user's download location is the default; editable in the UI so a move
    // doesn't need a rebuild.
    // ASR engine selection. Each engine runs from its own venv under enginesRoot
    // (their Python deps conflict), with weights in the sibling asr-models cache.
    @Published var engine: String = UserDefaults.standard.string(forKey: "asrEngine") ?? "whisper" {
        didSet {
            guard engine != oldValue else { return }
            UserDefaults.standard.set(engine, forKey: "asrEngine")
            remoteChunkCapability = nil
            remoteCapabilityIdentity = ""
            teardownServer()   // next transcription relaunches with the new engine
            status = "Engine: \(engineTitle)"
        }
    }
    static let engines: [(id: String, title: String)] = [
        ("whisper", "Whisper large-v3"),
        ("gigaam", "GigaAM v2 (Russian)"),
    ]
    var engineTitle: String { Self.engines.first { $0.id == engine }?.title ?? engine }
    private var enginesRoot: String {
        UserDefaults.standard.string(forKey: "asrEnginesRoot") ?? "/Users/daliys/Daliys/AI_Test_PlayGround/asr-engines"
    }
    private var modelsRoot: String {
        (enginesRoot as NSString).deletingLastPathComponent + "/asr-models"
    }
    private var keepLoadedMinutes: Int {
        UserDefaults.standard.object(forKey: "modelKeepLoadedMinutes") as? Int ?? 15
    }
    private var backend: String {
        UserDefaults.standard.string(forKey: "asrBackend") ?? "local"
    }
    private var usesRemoteServer: Bool { backend == "remote" }
    private var voiceServerURL: URL? {
        let raw = (UserDefaults.standard.string(forKey: "voiceServerURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let normalized = raw.contains("://") ? raw : "https://\(raw)"
        guard let url = URL(string: normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              url.scheme?.lowercased() == "https"
        else { return nil }
        return url
    }
    private var voiceServerURLProblem: String {
        let raw = (UserDefaults.standard.string(forKey: "voiceServerURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "Server URL is empty" }
        return "Server URL must use HTTPS (configure Tailscale Serve first)"
    }
    private var voiceServerToken: String {
        VoiceServerTokenStore.load()
    }
    private var remoteCapabilityConfigIdentity: String {
        "\(voiceServerURL?.absoluteString ?? "")|\(engine)"
    }
    private var voiceServerClientID: String {
        let key = "voiceServerClientID"
        if let existing = UserDefaults.standard.string(forKey: key),
           existing.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    private var port: Int?            // discovered at runtime (OS-assigned, no collisions)
    private var serverProcess: Process?
    private var activeRecordingURL: URL?
    private var recordingStartToken = 0
    private var player: AVAudioPlayer?
    private var playbackResetTask: Task<Void, Never>?
    private let portFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("soma_asr.port")
    private let logFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("soma_asr_server.log")

    // Mic audio is captured via AVAudioEngine, converted to 16 kHz mono, then written
    // to one WAV. Transcription runs after stop; saved audio survives failures.
    private var engineNode = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var procFormat: AVAudioFormat?
    private var fullFile: AVAudioFile?
    private var activeChunkCapture: VoiceChunkCapture?
    private var activeChunkPipeline: VoiceChunkPipeline?
    private var remoteChunkCapability: Bool?
    private var remoteCapabilityIdentity = ""
    private var recordingBeganAt: Date?
    private var receivedAudioSignal = false
    private var smoothedInputLevel = 0.0
    private var lastInputLevelPublishTime = 0.0
    private let audioQueue = DispatchQueue(label: "soma.asr.audio")
    private let targetSampleRate = 16000.0
    private let initialRecordingsLimit = 5
    private let recordingsPageSize = 20
    private var recordingIndex: [RecordingIndexEntry] = []
    private var importQueueTask: Task<Void, Never>?
    private var activeImportID: UUID?
    private var cancelledImportIDs = Set<UUID>()
    private weak var textPriorityQueue: VoiceTextPriorityQueue?
    private var queuedTranscriptions: [QueuedTranscription] = []
    private var transcriptionQueueTask: Task<Void, Never>?
    private let connectivityMonitor = NWPathMonitor()
    private let connectivityMonitorQueue = DispatchQueue(label: "soma.media-import.connectivity")

    // Recordings persist here (not /tmp) so a failed transcription never loses the take.
    private lazy var recordingsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soma/VoiceRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private lazy var importsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soma/MediaImports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("History", isDirectory: true), withIntermediateDirectories: true)
        return dir
    }()

    private var importQueueURL: URL { importsDir.appendingPathComponent("queue.json") }
    private var importHistoryURL: URL { importsDir.appendingPathComponent("history.json") }

    init() {
        migrateVoiceModelRetentionToFifteenMinutes()
        restoreImportQueue()
        connectivityMonitor.start(queue: connectivityMonitorQueue)
        pruneOldRecordings()
        installMemoryPressureUnload()
    }

    deinit {
        connectivityMonitor.cancel()
        memoryPressureSource?.cancel()
    }

    /// One hour was far too long on a RAM-bound box — a multi-GB model held for
    /// an hour after each use pushes the whole system into swap. Force 15 min
    /// once (supersedes the old one-hour migration), then honour later user edits.
    private func migrateVoiceModelRetentionToFifteenMinutes() {
        let migrationKey = "voiceModelRetentionFifteenMinMigrationV1"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        UserDefaults.standard.set(15, forKey: "modelKeepLoadedMinutes")
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    /// Free the local ASR model when the OS reports memory pressure and nothing
    /// is in flight, so Soma can't be the process that tips a tight box into
    /// swap thrash. Remote mode has no local model, so this is a no-op there.
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private func installMemoryPressureUnload() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            let critical = source.data.contains(.critical)
            MainActor.assumeIsolated {
                ResourceSampler.shared.mark(critical ? "mem_pressure_critical/asr" : "mem_pressure_warning/asr")
                guard let self, !self.usesRemoteServer, !self.isRecording, !self.isTranscribing else { return }
                self.teardownServer()
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    // MARK: Record toggle

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording(allowWhileTranscribing: true, useChunkedRemoteCapture: true)
        }
    }

    func startGlobalRecording() {
        // Global recordings may be captured while an earlier job is processing.
        // Their FLAC chunks still reach M1 while the global delivery queue
        // preserves paste order later.
        startRecording(allowWhileTranscribing: true, useChunkedRemoteCapture: true)
    }

    @MainActor
    func stopGlobalRecording() async -> String? {
        await stopRecordingAndTranscribe(source: .global)
    }

    @MainActor
    func finishGlobalRecording() async -> CapturedVoiceRecording? {
        await finishRecording(source: .global)
    }

    @MainActor
    func transcribeGlobalRecording(_ recording: CapturedVoiceRecording) async -> String? {
        await batchTranscribe(
            recording.url,
            source: .global,
            chunkPipeline: recording.chunkPipeline,
            expectedChunkCount: recording.expectedChunkCount
        )
    }

    func cancelRecording() {
        recordingStartToken += 1
        guard isRecording else { return }
        engineNode.inputNode.removeTap(onBus: 0)
        engineNode.stop()
        isRecording = false
        inputLevel = 0
        let recordedMilliseconds = recordingBeganAt.map { Int(Date().timeIntervalSince($0) * 1_000) } ?? 0
        recordingBeganAt = nil
        VoiceMetrics.log("recording_canceled", ["recorded_milliseconds": "\(recordedMilliseconds)"])
        status = "Recording canceled"
        let url = activeRecordingURL
        activeRecordingURL = nil
        let capture = activeChunkCapture
        let pipeline = activeChunkPipeline
        activeChunkCapture = nil
        activeChunkPipeline = nil
        if let pipeline {
            Task { await pipeline.cancel() }
        }
        audioQueue.async { [weak self] in
            guard let self else { return }
            capture?.cancel()
            self.fullFile = nil
            if let url { try? FileManager.default.removeItem(at: url) }
            DispatchQueue.main.async { self.refreshRecordings() }
        }
    }

    private func startRecording(allowWhileTranscribing: Bool = false, useChunkedRemoteCapture: Bool = true) {
        guard !isRecording, allowWhileTranscribing || !isTranscribing else { return }
        recordingStartToken += 1
        let token = recordingStartToken
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard let manager = self else { return }
            Task { @MainActor in
                guard token == manager.recordingStartToken else { return }
                guard granted else { manager.status = "Microphone access denied (System Settings → Privacy → Microphone)"; return }
                manager.beginStreamingRecording(
                    allowWhileTranscribing: allowWhileTranscribing,
                    useChunkedRemoteCapture: useChunkedRemoteCapture
                )
            }
        }
    }

    private var wavSettings: [String: Any] {
        // 16 kHz mono PCM WAV — what the ASR models want, and libsndfile reads it directly.
        [AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: targetSampleRate,
         AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
         AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    }

    private var transportFLACSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatFLAC),
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
        ]
    }

    /// Starts the chunked upload pipeline when the remote server can take it.
    /// The pipeline warms the model and probes /v1/health itself, so the other
    /// branches exist only for the cases where it does not run.
    @MainActor
    private func startChunkPipelineOrWarmBackend(useChunkedRemoteCapture: Bool) {
        activeChunkCapture = nil
        activeChunkPipeline = nil
        let capabilityHint = remoteCapabilityIdentity == remoteCapabilityConfigIdentity ? remoteChunkCapability : nil
        if useChunkedRemoteCapture, usesRemoteServer, capabilityHint != false, let base = voiceServerURL {
            let pipeline = VoiceChunkPipeline(
                base: base,
                token: voiceServerToken,
                clientID: voiceServerClientID,
                engine: engine,
                idleSeconds: keepLoadedMinutes * 60,
                workClass: .interactive,
                capabilityHint: capabilityHint,
                onCapabilities: { [weak self] health in
                    Task { @MainActor in self?.applyRemoteCapabilities(health) }
                }
            )
            activeChunkPipeline = pipeline
            activeChunkCapture = VoiceChunkCapture(settings: transportFLACSettings, fileExtension: "flac") { chunk in
                Task { await pipeline.enqueue(chunk) }
            }
            Task { await pipeline.start() }
            return
        }
        if usesRemoteServer {
            Task { await checkVoiceServer(silent: true) }
        } else {
            Task { _ = try? await ensureServerReady() }   // warm the model while recording
        }
    }

    @MainActor
    private func beginStreamingRecording(allowWhileTranscribing: Bool, useChunkedRemoteCapture: Bool) {
        ResourceSampler.shared.mark("record_start")
        stopPlayback()
        engineNode.stop()
        engineNode = AVAudioEngine()

        let input = engineNode.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { status = "No audio input available"; return }

        transcript = ""; lastInferSeconds = nil
        receivedAudioSignal = false
        inputLevel = 0
        audioQueue.async { [weak self] in
            self?.smoothedInputLevel = 0
            self?.lastInputLevelPublishTime = 0
        }

        startChunkPipelineOrWarmBackend(useChunkedRemoteCapture: useChunkedRemoteCapture)

        let fullURL = recordingsDir.appendingPathComponent("rec-\(Int(Date().timeIntervalSince1970)).wav")
        activeRecordingURL = fullURL
        do {
            let ff = try AVAudioFile(forWriting: fullURL, settings: wavSettings)
            fullFile = ff
            // The tap chooses the live hardware format, which may differ from the
            // format observed above. Build the converter from the first tap buffer.
            procFormat = ff.processingFormat
            converter = nil
        } catch {
            cancelPreparedChunkSession()
            fullFile = nil
            try? FileManager.default.removeItem(at: fullURL)
            activeRecordingURL = nil
            status = "Recorder error: \(error.localizedDescription)"; return
        }

        // The device's format can change between outputFormat(forBus:) and tap setup.
        // Passing nil keeps the tap on AVAudioEngine's live hardware format instead of
        // asking Core Audio to coerce it (which aborts on a format mismatch).
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.handleInput(buffer)
        }
        engineNode.prepare()
        do {
            try engineNode.start()
            isRecording = true
            if !allowWhileTranscribing { isTranscribing = false }
            recordingBeganAt = Date()
            VoiceMetrics.log("recording_started", [
                "backend": usesRemoteServer ? "remote" : "local",
                "engine": engine,
            ])
            status = "Recording…"
        } catch {
            input.removeTap(onBus: 0)
            cancelPreparedChunkSession()
            fullFile = nil
            try? FileManager.default.removeItem(at: fullURL)
            activeRecordingURL = nil
            status = "Could not start recording: \(error.localizedDescription)"
        }
    }

    /// Stop the engine, close the WAV, then transcribe it.
    func stopRecording() {
        Task { @MainActor in
            _ = await stopRecordingAndTranscribe(source: .inApp)
        }
    }

    @MainActor
    private func stopRecordingAndTranscribe(source: ASRTranscriptionSource) async -> String? {
        guard let recording = await finishRecording(source: source) else { return nil }
        return await batchTranscribe(
            recording.url,
            source: source,
            chunkPipeline: recording.chunkPipeline,
            expectedChunkCount: recording.expectedChunkCount
        )
    }

    @MainActor
    private func finishRecording(source: ASRTranscriptionSource) async -> CapturedVoiceRecording? {
        recordingStartToken += 1
        guard isRecording else { return nil }
        engineNode.inputNode.removeTap(onBus: 0)
        engineNode.stop()
        isRecording = false
        inputLevel = 0
        let recordedMilliseconds = recordingBeganAt.map { Int(Date().timeIntervalSince($0) * 1_000) } ?? 0
        recordingBeganAt = nil
        let sourceName: String
        switch source {
        case .global: sourceName = "global"
        case .inApp: sourceName = "in_app"
        }
        VoiceMetrics.log("recording_released", [
            "source": sourceName,
            "recorded_milliseconds": "\(recordedMilliseconds)",
        ])
        status = "Finishing transcription…"
        let capture = activeChunkCapture
        let pipeline = activeChunkPipeline
        activeChunkCapture = nil
        activeChunkPipeline = nil
        let closed: (URL?, Int, Bool) = await withCheckedContinuation { continuation in
            let activeURL = activeRecordingURL
            activeRecordingURL = nil
            audioQueue.async { [weak self] in
                guard let self else { continuation.resume(returning: (activeURL, 0, false)); return }
                let chunkCount = capture?.finish() ?? 0
                let receivedAudioSignal = self.receivedAudioSignal
                self.fullFile = nil        // close the full recording
                continuation.resume(returning: (activeURL, chunkCount, receivedAudioSignal))
            }
        }
        let fullURL = closed.0
        guard let fullURL else {
            if let pipeline { await pipeline.cancel() }
            return nil
        }
        lastRecordingURL = fullURL
        refreshRecordings()
        guard closed.2 else {
            if let pipeline { await pipeline.cancel() }
            status = "No microphone signal — reconnect or select the input device"
            return nil
        }
        return CapturedVoiceRecording(
            url: fullURL,
            chunkPipeline: pipeline,
            expectedChunkCount: closed.1
        )
    }

    // MARK: Capture

    /// Tap callback (audio render thread): resample to 16 kHz mono, hand off to the audio queue.
    private func handleInput(_ inBuffer: AVAudioPCMBuffer) {
        guard let procFormat else { return }
        if converter?.inputFormat.isEqual(inBuffer.format) != true {
            converter = AVAudioConverter(from: inBuffer.format, to: procFormat)
        }
        guard let converter else { return }
        let ratio = targetSampleRate / inBuffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: procFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return inBuffer
        }
        guard err == nil, out.frameLength > 0 else { return }
        audioQueue.async { [weak self] in self?.consume(out) }
    }

    private func consume(_ buf: AVAudioPCMBuffer) {
        if let samples = buf.floatChannelData?[0] {
            let count = Int(buf.frameLength)
            if !receivedAudioSignal {
                receivedAudioSignal = (0..<count).contains { abs(samples[$0]) > 0.002 }
            }
            if count > 0 {
                let sampleStride = max(1, count / 256)
                var sum = 0.0
                var sampled = 0
                for index in Swift.stride(from: 0, to: count, by: sampleStride) {
                    let value = Double(samples[index])
                    sum += value * value
                    sampled += 1
                }
                let rms = sqrt(sum / Double(max(sampled, 1)))
                let decibels = 20 * log10(max(rms, 0.000_1))
                let normalized = min(max((decibels + 48) / 42, 0), 1)
                smoothedInputLevel = smoothedInputLevel * 0.72 + normalized * 0.28

                let now = ProcessInfo.processInfo.systemUptime
                // Ten UI updates per second keep the meter responsive without
                // continuously restarting a longer SwiftUI interpolation.
                if now - lastInputLevelPublishTime >= 0.10 {
                    lastInputLevelPublishTime = now
                    let level = smoothedInputLevel
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isRecording else { return }
                        self.inputLevel = level
                    }
                }
            }
        }
        try? fullFile?.write(from: buf)
        activeChunkCapture?.consume(buf)
    }

    /// Called only before the audio tap can consume a buffer, so closing the
    /// temporary chunk writer here cannot race with the audio queue.
    private func cancelPreparedChunkSession() {
        let pipeline = activeChunkPipeline
        activeChunkPipeline = nil
        activeChunkCapture?.cancel()
        activeChunkCapture = nil
        if let pipeline {
            Task { await pipeline.cancel() }
        }
    }

    /// Re-transcribe a whole saved recording (batch path, e.g. the row "Transcribe" button).
    func transcribe(recording url: URL) {
        guard !isTranscribing, !isRecording else { return }
        lastRecordingURL = url
        Task { [weak self] in await self?.batchTranscribe(url, source: .inApp) }
    }

    @MainActor
    private func batchTranscribe(
        _ url: URL,
        source: ASRTranscriptionSource,
        chunkPipeline: VoiceChunkPipeline? = nil,
        expectedChunkCount: Int = 0
    ) async -> String? {
        await withCheckedContinuation { continuation in
            queuedTranscriptions.append(QueuedTranscription(
                url: url,
                source: source,
                chunkPipeline: chunkPipeline,
                expectedChunkCount: expectedChunkCount,
                continuation: continuation
            ))
            startTranscriptionQueueIfNeeded()
        }
    }

    @MainActor
    private func startTranscriptionQueueIfNeeded() {
        guard transcriptionQueueTask == nil, !queuedTranscriptions.isEmpty else { return }
        transcriptionQueueTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.queuedTranscriptions.isEmpty {
                let request = self.queuedTranscriptions.removeFirst()
                let result = await self.performBatchTranscribe(
                    request.url,
                    source: request.source,
                    chunkPipeline: request.chunkPipeline,
                    expectedChunkCount: request.expectedChunkCount
                )
                request.continuation.resume(returning: result)
            }
            self.transcriptionQueueTask = nil
        }
    }

    @MainActor
    private func performBatchTranscribe(
        _ url: URL,
        source: ASRTranscriptionSource,
        chunkPipeline: VoiceChunkPipeline? = nil,
        expectedChunkCount: Int = 0
    ) async -> String? {
        isTranscribing = true
        status = "Transcribing…"
        let text: String?
        if let chunkPipeline, usesRemoteServer, expectedChunkCount > 0 {
            text = await finishChunkedTranscription(chunkPipeline, expectedChunkCount: expectedChunkCount, fallbackURL: url)
        } else {
            if let chunkPipeline { await chunkPipeline.cancel() }
            if usesRemoteServer {
                VoiceMetrics.log("whole_file_path", [
                    "reason": expectedChunkCount == 0 ? "no_eligible_chunk" : "chunk_sessions_unsupported",
                ])
            }
            text = await transcribeFile(url)
        }
        isTranscribing = false
        transcript = text ?? ""
        status = (text ?? "").isEmpty ? "No speech detected" : "Done"
        if let text, !text.isEmpty {
            try? text.write(to: transcriptURL(for: url), atomically: true, encoding: .utf8)
            refreshRecordings()
        }
        lastTranscriptionSource = source
        completedTranscriptionID += 1
        return text
    }

    @MainActor
    private func finishChunkedTranscription(
        _ pipeline: VoiceChunkPipeline,
        expectedChunkCount: Int,
        fallbackURL: URL
    ) async -> String? {
        do {
            let result = try await pipeline.finalize(expectedChunkCount: expectedChunkCount)
            guard result.mergeSafe else {
                VoiceMetrics.log("whole_file_fallback", ["reason": "unsafe_forced_overlap_merge"])
                status = "Chunk merge needs full transcription; retrying…"
                return await transcribeRemotely(fallbackURL)
            }
            lastInferSeconds = result.inferSeconds
            return result.text
        } catch {
            VoiceMetrics.log("whole_file_fallback", ["reason": "chunk_session_error"])
            status = "Chunked transcription unavailable; retrying full recording…"
            return await transcribeRemotely(fallbackURL)
        }
    }

    // MARK: Recordings library

    /// Retention: drop saved recordings (and their transcripts) older than 14
    /// days so the VoiceRecordings cache can't grow without bound. Runs once at
    /// launch, off the main thread.
    private static let recordingRetention: TimeInterval = 14 * 24 * 60 * 60
    private func pruneOldRecordings() {
        let dir = recordingsDir
        let cutoff = Date().addingTimeInterval(-Self.recordingRetention)
        Task { [weak self, dir, cutoff] in
            await Task.detached(priority: .utility) {
                Self.removeRecordingFiles(in: dir, olderThan: cutoff)
            }.value
            self?.refreshRecordings()
        }
    }

    private nonisolated static func removeRecordingFiles(in dir: URL, olderThan cutoff: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        for url in files where url.pathExtension.lowercased() == "wav" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard date < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("txt"))
        }
    }

    func refreshRecordings() {
        // Scan off the main thread. This runs after *every* recording (incl. each
        // global paste), and the directory grows unbounded — a synchronous stat of
        // hundreds/thousands of files here hitched the UI/island animation and got
        // slower the longer the library grew.
        let dir = recordingsDir
        Task.detached(priority: .utility) { [weak self] in
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            let index = files
                .filter { $0.pathExtension.lowercased() == "wav" }
                .map { url -> RecordingIndexEntry in
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let transcript = url.deletingPathExtension().appendingPathExtension("txt")
                    return RecordingIndexEntry(url: url, date: date, hasTranscript: FileManager.default.fileExists(atPath: transcript.path))
                }
                .sorted { $0.date > $1.date }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.recordingIndex = index
                self.recordingsTotal = index.count
                self.recordings = []
                self.loadMoreRecordings(limit: self.initialRecordingsLimit)
            }
        }
    }

    var hasMoreRecordings: Bool { recordings.count < recordingsTotal }

    var nextRecordingsPageSize: Int {
        min(recordingsPageSize, max(recordingsTotal - recordings.count, 0))
    }

    func loadMoreRecordings() {
        loadMoreRecordings(limit: recordingsPageSize)
    }

    private func loadMoreRecordings(limit: Int) {
        let nextEntries = recordingIndex.dropFirst(recordings.count).prefix(limit)
        guard !nextEntries.isEmpty else { return }
        recordings.append(contentsOf: nextEntries.map { entry in
            let duration = (try? AVAudioPlayer(contentsOf: entry.url))?.duration ?? 0
            return VoiceRecording(
                url: entry.url,
                date: entry.date,
                duration: duration,
                hasTranscript: entry.hasTranscript
            )
        })
    }

    private func transcriptURL(for wav: URL) -> URL {
        wav.deletingPathExtension().appendingPathExtension("txt")
    }

    func hasTranscript(for wav: URL) -> Bool {
        FileManager.default.fileExists(atPath: transcriptURL(for: wav).path)
    }

    func transcript(for wav: URL) -> String {
        (try? String(contentsOf: transcriptURL(for: wav), encoding: .utf8)) ?? ""
    }

    func deleteRecording(_ url: URL) {
        if playingURL == url { stopPlayback() }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: transcriptURL(for: url))
        if lastRecordingURL == url { lastRecordingURL = nil }
        refreshRecordings()
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Transcript history / clipboard

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Whole history as one block, newest first: "date — transcript".
    func allTranscriptsText() -> String {
        recordingIndex
            .compactMap { entry -> String? in
                let t = transcript(for: entry.url)
                guard !t.isEmpty else { return nil }
                return "\(entry.date.formatted(date: .abbreviated, time: .shortened))\n\(t)"
            }
            .joined(separator: "\n\n———\n\n")
    }

    var hasAnyTranscript: Bool { recordingIndex.contains { $0.hasTranscript } }

    // MARK: Playback

    func togglePlayback(_ url: URL) {
        if playingURL == url { stopPlayback(); return }
        stopPlayback()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            player = p
            p.play()
            playingURL = url
            // No delegate — just clear the flag when the clip's duration elapses.
            playbackResetTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(p.duration * 1_000_000_000))
                if !Task.isCancelled { self?.playingURL = nil }
            }
        } catch {
            status = "Playback error: \(error.localizedDescription)"
        }
    }

    private func stopPlayback() {
        playbackResetTask?.cancel()
        playbackResetTask = nil
        player?.stop()
        player = nil
        playingURL = nil
    }

    // MARK: Imported media queue

    @MainActor
    func enqueueImportedFiles(_ urls: [URL], translateAfterTranscription: Bool = false) {
        let remoteURL = voiceServerURL?.absoluteString
        for url in urls where url.isFileURL {
            var job = MediaImportJob(sourceURL: url, backend: backend, engine: engine, remoteURL: remoteURL)
            job.translateAfterTranscription = translateAfterTranscription
            importJobs.append(job)
        }
        persistImportQueue()
        startImportQueueIfNeeded()
    }

    @MainActor
    func retryImport(_ id: UUID) {
        guard let index = importJobs.firstIndex(where: { $0.id == id }) else { return }
        importJobs[index].errorMessage = nil
        importJobs[index].retryCount = 0
        if importJobs[index].backend == "remote" {
            importJobs[index].remoteURL = voiceServerURL?.absoluteString
            importJobs[index].sessionID = nil
            importJobs[index].nextChunkIndex = 0
        }
        importJobs[index].phase = FileManager.default.fileExists(atPath: importJobs[index].sourcePath) ? .queued : .needsSource
        persistImportQueue()
        startImportQueueIfNeeded()
    }

    @MainActor
    func cancelImport(_ id: UUID) {
        guard let index = importJobs.firstIndex(where: { $0.id == id }) else { return }
        let job = importJobs.remove(at: index)
        cancelledImportIDs.insert(id)
        try? FileManager.default.removeItem(at: importWorkDirectory(for: job))
        persistImportQueue()
        if let rawURL = job.remoteURL, let base = URL(string: rawURL), let sessionID = job.sessionID {
            let token = voiceServerToken
            Task { await Self.cancelImportedSession(base: base, token: token, clientID: self.voiceServerClientID, sessionID: sessionID) }
        }
    }

    @MainActor
    func locateImportSource(_ id: UUID, at url: URL) {
        guard let index = importJobs.firstIndex(where: { $0.id == id }), url.isFileURL else { return }
        importJobs[index].sourcePath = url.path
        importJobs[index].displayName = url.lastPathComponent
        importJobs[index].phase = .queued
        importJobs[index].errorMessage = nil
        persistImportQueue()
        startImportQueueIfNeeded()
    }

    @MainActor
    func importedTranscript(for item: MediaImportHistory) -> String {
        (try? String(contentsOf: item.transcriptURL, encoding: .utf8)) ?? ""
    }

    @MainActor
    func importedTranslation(for item: MediaImportHistory) -> String {
        guard let url = item.translatedTranscriptURL else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @MainActor
    func configure(textPriorityQueue: VoiceTextPriorityQueue) {
        self.textPriorityQueue = textPriorityQueue
    }

    @MainActor
    func setImportedTranslation(_ id: UUID, path: URL) {
        guard let index = importHistory.firstIndex(where: { $0.id == id }) else { return }
        let current = importHistory[index]
        importHistory[index] = MediaImportHistory(
            id: current.id,
            displayName: current.displayName,
            completedAt: current.completedAt,
            transcriptPath: current.transcriptPath,
            translatedTranscriptPath: path.path,
            durationSeconds: current.durationSeconds
        )
        persistImportQueue()
    }

    @MainActor
    func resumeImportQueue() {
        startImportQueueIfNeeded()
    }

    private func restoreImportQueue() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: importQueueURL), let saved = try? decoder.decode([MediaImportJob].self, from: data) {
            importJobs = saved.map { savedJob in
                var job = savedJob
                job.prepareToResumeAfterRelaunch()
                return job
            }
        }
        if let data = try? Data(contentsOf: importHistoryURL), let saved = try? decoder.decode([MediaImportHistory].self, from: data) {
            importHistory = saved
        }
    }

    private func persistImportQueue() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(importJobs) { try? data.write(to: importQueueURL, options: .atomic) }
        if let data = try? encoder.encode(importHistory) { try? data.write(to: importHistoryURL, options: .atomic) }
    }

    @MainActor
    private func startImportQueueIfNeeded() {
        guard importQueueTask == nil, importJobs.contains(where: { $0.phase == .queued }) else { return }
        importQueueTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let job = self.importJobs.first(where: { $0.phase == .queued }) {
                self.activeImportID = job.id
                await self.processImport(job.id)
            }
            self.activeImportID = nil
            self.importQueueTask = nil
        }
    }

    @MainActor
    private func processImport(_ id: UUID) async {
        cancelledImportIDs.remove(id)
        guard var job = currentImport(id) else { return }
        guard FileManager.default.fileExists(atPath: job.sourcePath) else {
            updateImport(id, phase: .needsSource, error: "Source file was moved. Choose it again to resume.")
            return
        }
        do {
            if job.durationSeconds == nil || job.plannedChunks == nil {
                updateImport(id, phase: .probing)
                let duration: Double
                if let knownDuration = job.durationSeconds {
                    duration = knownDuration
                } else {
                    duration = try await MediaImportTools.probeDuration(job.sourceURL)
                }
                let chunks = try await MediaImportTools.planChunks(sourceURL: job.sourceURL, duration: duration)
                job = currentImport(id) ?? job
                job.durationSeconds = duration
                job.plannedChunks = chunks
                job.totalChunks = chunks.count
                if job.nextChunkIndex > 0 || job.sessionID != nil {
                    job.nextChunkIndex = 0
                    job.sessionID = nil
                    job.localFragments = []
                }
                replaceImport(job)
            }
            let text = job.backend == "remote"
                ? try await transcribeImportedRemotely(id)
                : try await transcribeImportedLocally(id)
            try completeImport(id, transcript: text)
        } catch is CancellationError {
            return
        } catch {
            updateImport(id, phase: .failed, error: error.localizedDescription)
        }
    }

    @MainActor
    private func transcribeImportedRemotely(_ id: UUID) async throws -> String {
        guard var job = currentImport(id), let rawURL = job.remoteURL,
              let base = URL(string: rawURL), base.scheme?.lowercased() == "https"
        else { throw SomaError("Remote imports require an HTTPS Soma Voice Server URL.") }
        let token = voiceServerToken
        guard !token.isEmpty else { throw SomaError("Set the Soma Voice Server token before importing media.") }
        let clientID = voiceServerClientID
        while true {
            do {
                if job.sessionID == nil {
                    updateImport(id, phase: .uploading)
                    let sessionID = try await retryImportRequest(id) {
                        try await self.createImportedSession(base: base, token: token, clientID: clientID, job: job)
                    }
                    job = currentImport(id) ?? job
                    job.sessionID = sessionID
                    replaceImport(job)
                }
                guard let sessionID = job.sessionID, let chunks = job.plannedChunks else {
                    throw SomaError("Import session could not be prepared.")
                }
                let total = chunks.count
                while job.nextChunkIndex < total {
                    let index = job.nextChunkIndex
                    let chunk = chunks[index]
                    let start = chunk.startSeconds
                    let chunkDuration = chunk.durationSeconds
                    updateImport(id, phase: .converting)
                    let chunkURL = importChunkURL(for: job, index: index)
                    try await MediaImportTools.exportChunk(sourceURL: job.sourceURL, startSeconds: start, durationSeconds: chunkDuration, to: chunkURL)
                    try ensureImportActive(id)
                    defer { try? FileManager.default.removeItem(at: chunkURL) }
                    updateImport(id, phase: .uploading)
                    let reason = VoiceChunkReason(rawValue: chunk.reason) ?? .forced
                    let overlapMilliseconds = Int(chunk.overlapSeconds * 1_000)
                    var jobID = try await retryImportRequest(id) {
                        try await self.uploadImportedChunk(base: base, token: token, clientID: clientID, sessionID: sessionID, job: job, index: index, attempt: 0, chunkURL: chunkURL, reason: reason, overlapMilliseconds: overlapMilliseconds, durationMilliseconds: Int(chunkDuration * 1_000))
                    }
                    do {
                        _ = try await retryImportRequest(id) {
                            try await self.waitForImportedChunk(base: base, token: token, clientID: clientID, jobID: jobID)
                        }
                    } catch let error as VoiceServerRemoteError where error.code == "pathological_repetition" {
                        jobID = try await retryImportRequest(id) {
                            try await self.uploadImportedChunk(base: base, token: token, clientID: clientID, sessionID: sessionID, job: job, index: index, attempt: 1, chunkURL: chunkURL, reason: reason, overlapMilliseconds: overlapMilliseconds, durationMilliseconds: Int(chunkDuration * 1_000), retryFailedChunk: true)
                        }
                        do {
                            _ = try await retryImportRequest(id) {
                                try await self.waitForImportedChunk(base: base, token: token, clientID: clientID, jobID: jobID)
                            }
                        } catch let retryError as VoiceServerRemoteError where retryError.code == "pathological_repetition" {
                            guard index > 0 else { throw retryError }
                            let contextURL = importWorkDirectory(for: job).appendingPathComponent(String(format: "chunk-%05d-context.flac", index))
                            defer { try? FileManager.default.removeItem(at: contextURL) }
                            let contextStart = chunks[index - 1].startSeconds
                            try await MediaImportTools.exportChunk(sourceURL: job.sourceURL, startSeconds: contextStart, durationSeconds: start + chunkDuration - contextStart, to: contextURL)
                            jobID = try await retryImportRequest(id) {
                                try await self.uploadImportedChunk(base: base, token: token, clientID: clientID, sessionID: sessionID, job: job, index: index, attempt: 2, chunkURL: contextURL, reason: reason, overlapMilliseconds: overlapMilliseconds, durationMilliseconds: Int(chunkDuration * 1_000), retryFailedChunk: true, contextChunkIndex: index - 1)
                            }
                            _ = try await retryImportRequest(id) {
                                try await self.waitForImportedChunk(base: base, token: token, clientID: clientID, jobID: jobID)
                            }
                        }
                    }
                    try ensureImportActive(id)
                    job = currentImport(id) ?? job
                    job.nextChunkIndex += 1
                    job.retryCount = 0
                    replaceImport(job)
                }
                updateImport(id, phase: .transcribing)
                try await retryImportRequest(id) { try await self.finalizeImportedSession(base: base, token: token, sessionID: sessionID) }
                let final = try await retryImportRequest(id) { try await self.waitForImportedSession(base: base, token: token, sessionID: sessionID) }
                return final.text ?? ""
            } catch is ImportedSessionLost {
                job = currentImport(id) ?? job
                job.sessionID = nil
                job.nextChunkIndex = 0
                job.retryCount = 0
                replaceImport(job)
            }
        }
    }

    @MainActor
    private func transcribeImportedLocally(_ id: UUID) async throws -> String {
        guard var job = currentImport(id), let chunks = job.plannedChunks else { throw SomaError("Import was not prepared.") }
        let total = chunks.count
        let localPort = try await ensureServerReady()
        while job.nextChunkIndex < total {
            let index = job.nextChunkIndex
            let chunk = chunks[index]
            let start = chunk.startSeconds
            let chunkDuration = chunk.durationSeconds
            updateImport(id, phase: .converting)
            let chunkURL = importChunkURL(for: job, index: index)
            try await MediaImportTools.exportChunk(sourceURL: job.sourceURL, startSeconds: start, durationSeconds: chunkDuration, to: chunkURL)
            try ensureImportActive(id)
            defer { try? FileManager.default.removeItem(at: chunkURL) }
            updateImport(id, phase: .transcribing)
            var fragment = try await transcribeImportedChunkLocally(chunkURL, port: localPort)
            if MediaImportTools.hasPathologicalRepetition(fragment) {
                fragment = try await transcribeImportedChunkLocally(chunkURL, port: localPort)
                if MediaImportTools.hasPathologicalRepetition(fragment) {
                    guard index > 0, let previous = job.localFragments.last else {
                        throw SomaError("The first media segment repeated itself excessively. Retry the import.")
                    }
                    let contextURL = importWorkDirectory(for: job).appendingPathComponent(String(format: "chunk-%05d-context.flac", index))
                    defer { try? FileManager.default.removeItem(at: contextURL) }
                    let contextStart = chunks[index - 1].startSeconds
                    try await MediaImportTools.exportChunk(sourceURL: job.sourceURL, startSeconds: contextStart, durationSeconds: start + chunkDuration - contextStart, to: contextURL)
                    let combined = try await transcribeImportedChunkLocally(contextURL, port: localPort)
                    guard !MediaImportTools.hasPathologicalRepetition(combined), let currentOnly = MediaImportTools.removingContextPrefix(previous, from: combined) else {
                        throw SomaError("A media segment could not be recovered safely. Retry the import.")
                    }
                    fragment = currentOnly
                }
            }
            try ensureImportActive(id)
            job = currentImport(id) ?? job
            job.localFragments.append(fragment)
            job.nextChunkIndex += 1
            replaceImport(job)
        }
        return job.localFragments.reduce("") { MediaImportTools.mergedText($0, with: $1) }
    }

    @MainActor
    private func completeImport(_ id: UUID, transcript: String) throws {
        guard let index = importJobs.firstIndex(where: { $0.id == id }) else { return }
        let job = importJobs[index]
        let textURL = importsDir.appendingPathComponent("History/\(job.id.uuidString).txt")
        try transcript.write(to: textURL, atomically: true, encoding: .utf8)
        importJobs.remove(at: index)
        importHistory.insert(MediaImportHistory(
            id: job.id,
            displayName: job.displayName,
            completedAt: Date(),
            transcriptPath: textURL.path,
            translatedTranscriptPath: nil,
            durationSeconds: job.durationSeconds
        ), at: 0)
        if job.shouldTranslateAfterTranscription {
            let translatedURL = importsDir.appendingPathComponent("History/\(job.id.uuidString).en.txt")
            textPriorityQueue?.enqueueBackgroundTranslation(importID: job.id, transcript: transcript, destination: translatedURL)
        }
        try? FileManager.default.removeItem(at: importWorkDirectory(for: job))
        persistImportQueue()
    }

    @MainActor
    private func currentImport(_ id: UUID) -> MediaImportJob? { importJobs.first(where: { $0.id == id }) }

    @MainActor
    private func replaceImport(_ job: MediaImportJob) {
        guard let index = importJobs.firstIndex(where: { $0.id == job.id }) else { return }
        importJobs[index] = job
        persistImportQueue()
    }

    @MainActor
    private func updateImport(_ id: UUID, phase: MediaImportPhase, error: String? = nil) {
        guard var job = currentImport(id) else { return }
        job.phase = phase
        job.errorMessage = error
        replaceImport(job)
    }

    private func importWorkDirectory(for job: MediaImportJob) -> URL {
        importsDir.appendingPathComponent("Work/\(job.id.uuidString)", isDirectory: true)
    }

    private func importChunkURL(for job: MediaImportJob, index: Int) -> URL {
        let directory = importWorkDirectory(for: job)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(String(format: "chunk-%05d.flac", index))
    }

    private func retryImportRequest<T>(_ id: UUID, operation: @escaping () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            try ensureImportActive(id)
            do { return try await operation() }
            catch is ImportedSessionLost { throw ImportedSessionLost() }
            catch let error as VoiceServerRemoteError where error.code == "pathological_repetition" { throw error }
            catch let error as VoiceServerRemoteError where !error.retryable { throw error }
            catch {
                attempt += 1
                guard var job = currentImport(id) else { throw CancellationError() }
                job.phase = .waitingForNetwork
                job.retryCount = attempt
                job.errorMessage = "Retrying: \(error.localizedDescription)"
                replaceImport(job)
                let seconds = min(60.0, pow(2.0, Double(min(attempt - 1, 6)))) + Double.random(in: 0...0.5)
                try await waitForConnectivityOrDelay(seconds)
            }
        }
    }

    private func waitForConnectivityOrDelay(_ seconds: Double) async throws {
        let startedOffline = connectivityMonitor.currentPath.status != .satisfied
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int(seconds * 1_000)))
        while clock.now < deadline {
            try Task.checkCancellation()
            if startedOffline, connectivityMonitor.currentPath.status == .satisfied { return }
            let remaining = clock.now.duration(to: deadline)
            try await Task.sleep(for: min(remaining, .milliseconds(250)))
        }
    }

    private struct ImportedSessionLost: Error {}

    @MainActor
    private func ensureImportActive(_ id: UUID) throws {
        guard !cancelledImportIDs.contains(id), currentImport(id) != nil else { throw CancellationError() }
    }

    private func importRemoteRequest(_ url: URL, token: String, clientID: String, engine: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "X-Soma-Client-ID")
        if let engine { request.setValue(engine, forHTTPHeaderField: "X-Soma-Engine") }
        return request
    }

    private func createImportedSession(base: URL, token: String, clientID: String, job: MediaImportJob) async throws -> String {
        var request = importRemoteRequest(base.appendingPathComponent("v1/sessions"), token: token, clientID: clientID, engine: job.engine)
        request.httpMethod = "POST"
        request.setValue(job.sessionRequestID, forHTTPHeaderField: "X-Soma-Request-ID")
        request.setValue(String(keepLoadedMinutes * 60), forHTTPHeaderField: "X-Soma-Idle-Seconds")
        request.setValue("auto", forHTTPHeaderField: "X-Soma-Language")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (code == 200 || code == 201), let session = try? JSONDecoder().decode(VoiceServerSessionResponse.self, from: data), let id = session.session_id else {
            throw remoteError(data, fallback: "Could not create import session (HTTP \(code)).", retryable: code >= 500 || code == 408 || code == 429)
        }
        return id
    }

    private func uploadImportedChunk(base: URL, token: String, clientID: String, sessionID: String, job: MediaImportJob, index: Int, attempt: Int, chunkURL: URL, reason: VoiceChunkReason, overlapMilliseconds: Int, durationMilliseconds: Int, retryFailedChunk: Bool = false, contextChunkIndex: Int? = nil) async throws -> String {
        var request = importRemoteRequest(base.appendingPathComponent("v1/sessions/\(sessionID)/chunks/\(index)"), token: token, clientID: clientID, engine: job.engine)
        request.httpMethod = "PUT"
        request.setValue("audio/flac", forHTTPHeaderField: "Content-Type")
        request.setValue(VoiceWorkClass.background.rawValue, forHTTPHeaderField: "X-Soma-Work-Class")
        request.setValue("client-v1", forHTTPHeaderField: "X-Soma-Chunk-Recovery")
        request.setValue("\(job.id.uuidString)-\(index)-\(attempt)", forHTTPHeaderField: "X-Soma-Request-ID")
        request.setValue(reason.rawValue, forHTTPHeaderField: "X-Soma-Chunk-Reason")
        request.setValue("\(overlapMilliseconds)", forHTTPHeaderField: "X-Soma-Overlap-Milliseconds")
        request.setValue("\(durationMilliseconds)", forHTTPHeaderField: "X-Soma-Chunk-Duration-Milliseconds")
        if retryFailedChunk { request.setValue("1", forHTTPHeaderField: "X-Soma-Retry-Failed-Chunk") }
        if let contextChunkIndex { request.setValue("\(contextChunkIndex)", forHTTPHeaderField: "X-Soma-Context-Chunk-Index") }
        request.timeoutInterval = 90
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: chunkURL)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw ImportedSessionLost() }
        guard code == 202, let payload = try? JSONDecoder().decode(VoiceServerJobResponse.self, from: data), let jobID = payload.job_id else {
            throw remoteError(data, fallback: "Import chunk upload failed (HTTP \(code)).", retryable: code >= 500 || code == 408 || code == 429)
        }
        return jobID
    }

    private func waitForImportedChunk(base: URL, token: String, clientID: String, jobID: String) async throws -> String {
        while true {
            var components = URLComponents(url: base.appendingPathComponent("v1/transcriptions/\(jobID)"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "wait", value: "25")]
            var request = importRemoteRequest(components.url!, token: token, clientID: clientID)
            request.timeoutInterval = 35
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { throw ImportedSessionLost() }
            guard code == 200, let payload = try? JSONDecoder().decode(VoiceServerJobResponse.self, from: data) else {
                throw remoteError(data, fallback: "Import chunk polling failed (HTTP \(code)).", retryable: code >= 500 || code == 408)
            }
            switch payload.status {
            case "done": return payload.text ?? ""
            case "failed":
                let detail = payload.error
                throw VoiceServerRemoteError(code: detail?.code ?? "transcription_failed", message: detail?.message ?? "Import chunk failed.", retryable: detail?.retryable ?? true)
            default: continue
            }
        }
    }

    private func finalizeImportedSession(base: URL, token: String, sessionID: String) async throws {
        var request = importRemoteRequest(base.appendingPathComponent("v1/sessions/\(sessionID)/finalize"), token: token, clientID: voiceServerClientID)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw ImportedSessionLost() }
        guard code == 200 else { throw remoteError(data, fallback: "Could not finalize import session.", retryable: code >= 500 || code == 408) }
    }

    private func waitForImportedSession(base: URL, token: String, sessionID: String) async throws -> VoiceServerSessionResponse {
        while true {
            var components = URLComponents(url: base.appendingPathComponent("v1/sessions/\(sessionID)"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "wait", value: "25")]
            var request = importRemoteRequest(components.url!, token: token, clientID: voiceServerClientID)
            request.timeoutInterval = 35
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { throw ImportedSessionLost() }
            guard code == 200, let payload = try? JSONDecoder().decode(VoiceServerSessionResponse.self, from: data) else {
                throw remoteError(data, fallback: "Import session polling failed (HTTP \(code)).", retryable: code >= 500 || code == 408)
            }
            switch payload.status {
            case "done": return payload
            case "failed", "canceled": throw SomaError(payload.error?.message ?? "Import session did not complete.")
            default: continue
            }
        }
    }

    private func transcribeImportedChunkLocally(_ url: URL, port: Int) async throws -> String {
        let payload: [String: Any] = [
            "audio": url.path,
            "idle_seconds": keepLoadedMinutes * 60,
            "language": "auto",
        ]
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/transcribe")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 600
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SomaError(object["error"] as? String ?? "Local transcription failed.") }
        return object["text"] as? String ?? ""
    }

    private static func cancelImportedSession(base: URL, token: String, clientID: String, sessionID: String) async {
        guard !token.isEmpty else { return }
        var request = URLRequest(url: base.appendingPathComponent("v1/sessions/\(sessionID)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "X-Soma-Client-ID")
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: Transcription

    /// POST one WAV to the warm server and return its transcript (nil on error).
    /// Used for both new recordings and saved-file re-transcription.
    private func transcribeFile(_ audioURL: URL) async -> String? {
        if usesRemoteServer {
            return await transcribeRemotely(audioURL)
        }
        do {
            let port = try await ensureServerReady()
            let payload: [String: Any] = [
                "audio": audioURL.path,
                "idle_seconds": keepLoadedMinutes * 60,
            ]
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/transcribe")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            req.timeoutInterval = 600  // first call may load the model

            let (data, response) = try await URLSession.shared.data(for: req)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
                await MainActor.run { status = "Transcription failed: \(obj["error"] as? String ?? "HTTP \(code)")" }
                return nil
            }
            if let secs = obj["infer_seconds"] as? Double { await MainActor.run { lastInferSeconds = secs } }
            return (obj["text"] as? String) ?? ""
        } catch {
            await MainActor.run { status = "Error: \(error.localizedDescription)" }
            return nil
        }
    }

    @MainActor
    func checkVoiceServer(silent: Bool = false) async {
        guard let base = voiceServerURL else {
            remoteChunkCapability = nil
            remoteCapabilityIdentity = ""
            voiceServerConnectionState = .offline
            voiceServerStatusDetail = voiceServerURLProblem
            if !silent { status = voiceServerURLProblem }
            return
        }
        voiceServerConnectionState = .checking
        voiceServerStatusDetail = "Checking \(base.host ?? base.absoluteString)…"
        do {
            var req = remoteRequest(base.appendingPathComponent("v1/health"))
            req.timeoutInterval = 5
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let message = remoteErrorMessage(data) ?? "HTTP error"
                remoteChunkCapability = nil
                remoteCapabilityIdentity = ""
                voiceServerConnectionState = .offline
                voiceServerStatusDetail = message
                if !silent { status = "Voice Server check failed: \(message)" }
                return
            }
            applyRemoteCapabilities(try? JSONDecoder().decode(VoiceServerHealth.self, from: data))
            if !silent { status = "Voice Server online." }
        } catch {
            applyRemoteCapabilities(nil)
            voiceServerStatusDetail = error.localizedDescription
            if !silent { status = "Voice Server unavailable: \(error.localizedDescription)" }
        }
    }

    /// Records what one /v1/health answer tells us. Shared so a recording's own
    /// probe updates the cache and the badge without a second request.
    @MainActor
    func applyRemoteCapabilities(_ health: VoiceServerHealth?) {
        guard let health else {
            remoteChunkCapability = nil
            remoteCapabilityIdentity = ""
            voiceServerConnectionState = .offline
            voiceServerStatusDetail = "Unreachable"
            return
        }
        let capabilities = Set(health.capabilities ?? [])
        remoteChunkCapability = (health.version ?? 0) >= 2
            && capabilities.isSuperset(of: ["warmup", "chunk_sessions", "long_poll"])
        remoteCapabilityIdentity = remoteCapabilityConfigIdentity
        voiceServerConnectionState = .online
        voiceServerStatusDetail = "Online"
    }

    private func transcribeRemotely(_ audioURL: URL) async -> String? {
        guard let base = voiceServerURL else {
            await MainActor.run {
                voiceServerConnectionState = .offline
                voiceServerStatusDetail = voiceServerURLProblem
                status = voiceServerURLProblem
            }
            return nil
        }
        do {
            let startedAt = Date()
            let audio = try Data(contentsOf: audioURL)
            let requestID = UUID().uuidString
            let jobID = try await submitRemoteJob(base: base, audio: audio, requestID: requestID)
            await MainActor.run {
                voiceServerConnectionState = .online
                voiceServerStatusDetail = "Online"
                status = "Queued on Soma Voice Server…"
            }
            do {
                let text = try await pollRemoteJob(base: base, jobID: jobID)
                VoiceMetrics.log("whole_file_finished", [
                    "release_to_final_milliseconds": "\(Int(Date().timeIntervalSince(startedAt) * 1_000))",
                ])
                return text
            } catch let error as VoiceServerRemoteError where error.retryable || error.code == "job_not_found" {
                await MainActor.run { status = "Voice Server lost job; retrying…" }
                let retryJobID = try await submitRemoteJob(base: base, audio: audio, requestID: UUID().uuidString)
                let text = try await pollRemoteJob(base: base, jobID: retryJobID)
                VoiceMetrics.log("whole_file_finished", [
                    "release_to_final_milliseconds": "\(Int(Date().timeIntervalSince(startedAt) * 1_000))",
                    "retried": "true",
                ])
                return text
            }
        } catch {
            await MainActor.run {
                voiceServerConnectionState = .offline
                voiceServerStatusDetail = error.localizedDescription
                status = "Voice Server error: \(error.localizedDescription)"
            }
            return nil
        }
    }

    private func submitRemoteJob(base: URL, audio: Data, requestID: String) async throws -> String {
        var lastError: Error?
        for _ in 0..<3 {
            do {
                var req = remoteRequest(base.appendingPathComponent("v1/transcriptions"))
                req.httpMethod = "POST"
                req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
                req.setValue(voiceServerClientID, forHTTPHeaderField: "X-Soma-Client-ID")
                req.setValue(requestID, forHTTPHeaderField: "X-Soma-Request-ID")
                req.setValue(engine, forHTTPHeaderField: "X-Soma-Engine")
                req.setValue(String(keepLoadedMinutes * 60), forHTTPHeaderField: "X-Soma-Idle-Seconds")
                req.httpBody = audio
                req.timeoutInterval = 60
                let (data, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 202,
                      let payload = try? JSONDecoder().decode(VoiceServerJobResponse.self, from: data),
                      let jobID = payload.job_id
                else {
                    throw remoteError(data, fallback: "Upload failed (HTTP \(code)).", retryable: code >= 500)
                }
                return jobID
            } catch {
                if let remoteError = error as? VoiceServerRemoteError, !remoteError.retryable {
                    throw remoteError
                }
                lastError = error
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
        throw lastError ?? SomaError("Upload failed.")
    }

    private func pollRemoteJob(base: URL, jobID: String) async throws -> String {
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            do {
                var components = URLComponents(url: base.appendingPathComponent("v1/transcriptions/\(jobID)"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "wait", value: "25")]
                var req = remoteRequest(components.url!)
                req.timeoutInterval = 30
                let (data, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200,
                      let payload = try? JSONDecoder().decode(VoiceServerJobResponse.self, from: data)
                else {
                    throw remoteError(data, fallback: "Polling failed (HTTP \(code)).", retryable: code >= 500)
                }
                switch payload.status {
                case "done":
                    await MainActor.run { lastInferSeconds = payload.infer_seconds }
                    return payload.text ?? ""
                case "failed":
                    let detail = payload.error
                    throw VoiceServerRemoteError(
                        code: detail?.code ?? "transcription_failed",
                        message: detail?.message ?? "Remote transcription \(payload.status ?? "failed").",
                        retryable: detail?.retryable ?? true
                    )
                default:
                    let queued = payload.queued_seconds.map { String(format: "%.1fs", $0) } ?? "waiting"
                    await MainActor.run { status = "Voice Server \(payload.status ?? "queued") (\(queued))…" }
                }
            } catch {
                if let remoteError = error as? VoiceServerRemoteError { throw remoteError }
                if let somaError = error as? SomaError { throw somaError }
                await MainActor.run { status = "Waiting for Soma Voice Server…" }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw SomaError("Remote transcription timed out.")
    }

    private func remoteRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = voiceServerToken
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func remoteErrorMessage(_ data: Data) -> String? {
        (try? JSONDecoder().decode(VoiceServerErrorEnvelope.self, from: data).error?.message)
    }

    private func remoteError(_ data: Data, fallback: String, retryable: Bool) -> VoiceServerRemoteError {
        let detail = (try? JSONDecoder().decode(VoiceServerErrorEnvelope.self, from: data).error)
        return VoiceServerRemoteError(
            code: detail?.code ?? "http_error",
            message: detail?.message ?? fallback,
            retryable: detail?.retryable ?? retryable
        )
    }

    // MARK: Warm server lifecycle

    /// Returns the live server port, launching the server if needed. The port is
    /// OS-assigned (server binds :0) and reported via the port file, so we never
    /// collide with other local servers the user runs.
    private func ensureServerReady() async throws -> Int {
        if let p = port, await isOurServer(p) { return p }
        if let p = readPortFile(), await isOurServer(p) { port = p; return p }

        try launchServer()
        status = "Loading model… (first run is slow)"
        for _ in 0..<120 {  // up to ~60s for the server to bind and write its port
            try await Task.sleep(nanoseconds: 500_000_000)
            if let p = readPortFile(), await isOurServer(p) { port = p; return p }
        }
        let log = (try? String(contentsOf: logFileURL, encoding: .utf8))?.suffix(400) ?? ""
        throw SomaError("ASR server did not start. Check the engines folder and the '\(engine)' venv.\n\(log)")
    }

    private func readPortFile() -> Int? {
        guard let s = try? String(contentsOf: portFileURL, encoding: .utf8) else { return nil }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True only if our server answers /health — guards against a stale port file
    /// or a foreign server squatting on the port.
    private func isOurServer(_ port: Int) async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 2
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        guard obj["ok"] as? Bool == true else { return false }
        // A live server running a different engine than the current selection is
        // not "ours" — force a relaunch so the picked engine actually takes effect.
        if let running = obj["engine"] as? String, running != engine { return false }
        return true
    }

    private func teardownServer() {
        serverProcess?.terminate()
        serverProcess = nil
        port = nil
        try? FileManager.default.removeItem(at: portFileURL)
    }

    private func launchServer() throws {
        if let p = serverProcess, p.isRunning { return }
        try? FileManager.default.removeItem(at: portFileURL)
        let root = enginesRoot.trimmingCharacters(in: .whitespaces)
        let venvPython = "\(root)/venv-\(engine)/bin/python"
        guard FileManager.default.fileExists(atPath: venvPython) else {
            throw SomaError("ASR venv for '\(engineTitle)' not found at \(venvPython)")
        }
        let script = "\(root)/asr_server.py"
        guard FileManager.default.fileExists(atPath: script) else {
            throw SomaError("asr_server.py not found at \(script)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: venvPython)
        process.arguments = [script]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        var env = ProcessInfo.processInfo.environment
        // Xcode injects Metal API-validation vars into the app's env; if they leak into
        // the torch/MPS child its compute kernels abort (SIGABRT) under the stricter
        // validation layer. Strip them so the server runs like it does from a terminal.
        for key in ["METAL_DEVICE_WRAPPER_TYPE", "METAL_DEBUG_ERROR_MODE", "METAL_ERROR_MODE",
                    "MTL_DEBUG_LAYER", "MTL_SHADER_VALIDATION"] {
            env.removeValue(forKey: key)
        }
        // A GUI app launched from Finder/Xcode inherits a minimal PATH (no /opt/homebrew/bin),
        // so child tools like ffmpeg aren't found. Prepend the Homebrew/local bins.
        let basePath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + basePath
        env["ASR_ENGINE"] = engine
        env["ASR_PORT"] = "0"   // OS picks a free port
        env["ASR_PORT_FILE"] = portFileURL.path
        env["ASR_IDLE_SECONDS"] = String(keepLoadedMinutes * 60)
        env["HF_HOME"] = "\(modelsRoot)/hf"                // Whisper (mlx) weights cache
        env["ASR_GIGAAM_ROOT"] = "\(modelsRoot)/gigaam"    // GigaAM checkpoint dir
        env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        // Capture stdout+stderr so a failed start is diagnosable.
        FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            process.standardOutput = handle
            process.standardError = handle
        }
        try process.run()
        serverProcess = process
    }
}

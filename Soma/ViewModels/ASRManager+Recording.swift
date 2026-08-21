import AVFoundation
import Foundation
import SwiftUI

extension ASRManager {
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

    func startRecording(allowWhileTranscribing: Bool = false, useChunkedRemoteCapture: Bool = true) {
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

    var wavSettings: [String: Any] {
        // 16 kHz mono PCM WAV — what the ASR models want, and libsndfile reads it directly.
        [AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: targetSampleRate,
         AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
         AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    }

    var transportFLACSettings: [String: Any] {
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
    func startChunkPipelineOrWarmBackend(useChunkedRemoteCapture: Bool) {
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
                onCapabilities: { health in
                    // Inner [weak self]: Swift 6 rejects reading the outer captured var.
                    Task { @MainActor [weak self] in self?.applyRemoteCapabilities(health) }
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
    func beginStreamingRecording(allowWhileTranscribing: Bool, useChunkedRemoteCapture: Bool) {
        ResourceSampler.shared.mark("record_start")
        stopPlayback()
        engineNode.stop()
        engineNode = AVAudioEngine()
        let input = engineNode.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { status = "No audio input available"; return }
        resetRecordingState()
        startChunkPipelineOrWarmBackend(useChunkedRemoteCapture: useChunkedRemoteCapture)
        // Milliseconds, not seconds: AVAudioFile(forWriting:) truncates, so two
        // starts inside one second would clobber a WAV still being transcribed.
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let fullURL = recordingsDir.appendingPathComponent("rec-\(stamp).wav")
        activeRecordingURL = fullURL
        guard prepareRecordingFile(at: fullURL) else { return }
        startRecordingEngine(input, fullURL: fullURL, allowWhileTranscribing: allowWhileTranscribing)
    }

    @MainActor
    func resetRecordingState() {
        transcript = ""; lastInferSeconds = nil
        receivedAudioSignal = false
        inputLevel = 0
        audioQueue.async { [weak self] in
            self?.smoothedInputLevel = 0
            self?.lastInputLevelPublishTime = 0
        }
    }

    func prepareRecordingFile(at url: URL) -> Bool {
        do {
            let file = try AVAudioFile(forWriting: url, settings: wavSettings)
            fullFile = file
            procFormat = file.processingFormat
            converter = nil
            return true
        } catch {
            cancelPreparedChunkSession()
            fullFile = nil
            try? FileManager.default.removeItem(at: url)
            activeRecordingURL = nil
            status = "Recorder error: \(error.localizedDescription)"
            return false
        }
    }

    @MainActor
    func startRecordingEngine(_ input: AVAudioInputNode, fullURL: URL, allowWhileTranscribing: Bool) {
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
    func stopRecordingAndTranscribe(source: ASRTranscriptionSource) async -> String? {
        guard let recording = await finishRecording(source: source) else { return nil }
        return await batchTranscribe(
            recording.url,
            source: source,
            chunkPipeline: recording.chunkPipeline,
            expectedChunkCount: recording.expectedChunkCount
        )
    }

    @MainActor
    func finishRecording(source: ASRTranscriptionSource) async -> CapturedVoiceRecording? {
        recordingStartToken += 1
        guard isRecording else { return nil }
        engineNode.inputNode.removeTap(onBus: 0)
        engineNode.stop()
        isRecording = false
        inputLevel = 0
        let recordedMilliseconds = recordingBeganAt.map { Int(Date().timeIntervalSince($0) * 1_000) } ?? 0
        recordingBeganAt = nil
        VoiceMetrics.log("recording_released", [
            "source": source == .global ? "global" : "in_app",
            "recorded_milliseconds": "\(recordedMilliseconds)",
        ])
        status = "Finishing transcription…"
        let capture = activeChunkCapture
        let pipeline = activeChunkPipeline
        activeChunkCapture = nil
        activeChunkPipeline = nil
        let closed = await closeRecording(capture)
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

    func closeRecording(_ capture: VoiceChunkCapture?) async -> (URL?, Int, Bool) {
        await withCheckedContinuation { continuation in
            let activeURL = activeRecordingURL
            activeRecordingURL = nil
            audioQueue.async { [weak self] in
                guard let self else { continuation.resume(returning: (activeURL, 0, false)); return }
                let chunkCount = capture?.finish() ?? 0
                self.fullFile = nil
                continuation.resume(returning: (activeURL, chunkCount, self.receivedAudioSignal))
            }
        }
    }
}

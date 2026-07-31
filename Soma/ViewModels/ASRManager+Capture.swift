import AVFoundation
import Foundation

extension ASRManager {
    // MARK: Capture

    /// Tap callback (audio render thread): resample to 16 kHz mono, hand off to the audio queue.
    func handleInput(_ inBuffer: AVAudioPCMBuffer) {
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

    func consume(_ buf: AVAudioPCMBuffer) {
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
    func cancelPreparedChunkSession() {
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
    func batchTranscribe(
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
    func startTranscriptionQueueIfNeeded() {
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
    func performBatchTranscribe(
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
    func finishChunkedTranscription(_ pipeline: VoiceChunkPipeline, expectedChunkCount: Int, fallbackURL: URL) async -> String? {
        do {
            let result = try await pipeline.finalize(expectedChunkCount: expectedChunkCount)
            if !result.mergeSafe {
                // Seam words duplicated, never lost. Re-transcribing the whole
                // recording to avoid that cost 2.12x decode for 0.057 WER of
                // unproven direction — Scripts/whisper_chunk_merge_bench.py.
                VoiceMetrics.log("merge_seam_unmatched", ["kept_chunked_result": "true"])
            }
            lastInferSeconds = result.inferSeconds
            return result.text
        } catch {
            VoiceMetrics.log("whole_file_fallback", ["reason": "chunk_session_error"])
            status = "Chunked transcription unavailable; retrying full recording…"
            return await transcribeRemotely(fallbackURL)
        }
    }
}

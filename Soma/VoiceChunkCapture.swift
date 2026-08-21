import AVFoundation
import Foundation

enum VoiceChunkReason: String, Sendable {
    case pause
    case forced
    case final
}

/// Interactive dictation always runs before queued media imports. A currently
/// running MLX inference is deliberately never interrupted.

nonisolated struct VoiceChunk: Sendable {
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

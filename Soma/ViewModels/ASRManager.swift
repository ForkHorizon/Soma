import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

struct VoiceRecording: Identifiable, Hashable {
    let url: URL
    let date: Date
    let duration: Double
    let hasTranscript: Bool   // saved alongside the audio as a sidecar .txt
    var id: URL { url }
}

enum ASRTranscriptionSource {
    case inApp
    case global
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
    @Published var completedTranscriptionID = 0   // bumped when a recording is FULLY transcribed (final)
    @Published var lastTranscriptionSource: ASRTranscriptionSource = .inApp

    // Settings live in UserDefaults so the view's @AppStorage and this manager share them.
    // ponytail: user's download location is the default; editable in the UI so a move
    // doesn't need a rebuild.
    // ASR engine selection. Each engine runs from its own venv under enginesRoot
    // (their Python deps conflict), with weights in the sibling asr-models cache.
    @Published var engine: String = UserDefaults.standard.string(forKey: "asrEngine") ?? "whisper" {
        didSet {
            guard engine != oldValue else { return }
            UserDefaults.standard.set(engine, forKey: "asrEngine")
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
        UserDefaults.standard.object(forKey: "modelKeepLoadedMinutes") as? Int ?? 10
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
    private let engineNode = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var procFormat: AVAudioFormat?
    private var fullFile: AVAudioFile?
    private let audioQueue = DispatchQueue(label: "soma.asr.audio")
    private let targetSampleRate = 16000.0

    // Recordings persist here (not /tmp) so a failed transcription never loses the take.
    private lazy var recordingsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soma/VoiceRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: Record toggle

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startGlobalRecording() {
        startRecording()
    }

    @MainActor
    func stopGlobalRecording() async -> String? {
        await stopRecordingAndTranscribe(source: .global)
    }

    func cancelRecording() {
        recordingStartToken += 1
        guard isRecording else { return }
        engineNode.inputNode.removeTap(onBus: 0)
        engineNode.stop()
        isRecording = false
        isTranscribing = false
        status = "Recording canceled"
        let url = activeRecordingURL
        activeRecordingURL = nil
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.fullFile = nil
            if let url { try? FileManager.default.removeItem(at: url) }
            DispatchQueue.main.async { self.refreshRecordings() }
        }
    }

    private func startRecording() {
        guard !isRecording, !isTranscribing else { return }
        recordingStartToken += 1
        let token = recordingStartToken
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard let manager = self else { return }
            Task { @MainActor in
                guard token == manager.recordingStartToken else { return }
                guard granted else { manager.status = "Microphone access denied (System Settings → Privacy → Microphone)"; return }
                manager.beginStreamingRecording()
            }
        }
    }

    private var wavSettings: [String: Any] {
        // 16 kHz mono PCM WAV — what the ASR models want, and libsndfile reads it directly.
        [AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: targetSampleRate,
         AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
         AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    }

    @MainActor
    private func beginStreamingRecording() {
        stopPlayback()
        Task { _ = try? await ensureServerReady() }   // warm the model while recording

        let input = engineNode.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { status = "No audio input available"; return }

        transcript = ""; lastInferSeconds = nil

        let fullURL = recordingsDir.appendingPathComponent("rec-\(Int(Date().timeIntervalSince1970)).wav")
        activeRecordingURL = fullURL
        do {
            let ff = try AVAudioFile(forWriting: fullURL, settings: wavSettings)
            fullFile = ff
            // Convert mic audio straight into the file's processing format, so write(from:) is accepted.
            let proc = ff.processingFormat
            guard let conv = AVAudioConverter(from: inFormat, to: proc) else {
                status = "Could not initialize audio converter"; return
            }
            procFormat = proc
            converter = conv
        } catch {
            status = "Recorder error: \(error.localizedDescription)"; return
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.handleInput(buffer)
        }
        engineNode.prepare()
        do {
            try engineNode.start()
            isRecording = true
            isTranscribing = false
            status = "Recording…"
        } catch {
            input.removeTap(onBus: 0)
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
        recordingStartToken += 1
        guard isRecording else { return nil }
        engineNode.inputNode.removeTap(onBus: 0)
        engineNode.stop()
        isRecording = false
        isTranscribing = true
        status = "Finishing transcription…"
        let fullURL = await withCheckedContinuation { continuation in
            let activeURL = activeRecordingURL
            activeRecordingURL = nil
            audioQueue.async { [weak self] in
                guard let self else { continuation.resume(returning: activeURL); return }
                self.fullFile = nil        // close the full recording
                continuation.resume(returning: activeURL)
            }
        }
        guard let fullURL else {
            isTranscribing = false
            return nil
        }
        lastRecordingURL = fullURL
        refreshRecordings()
        return await batchTranscribe(fullURL, source: source)
    }

    // MARK: Capture

    /// Tap callback (audio render thread): resample to 16 kHz mono, hand off to the audio queue.
    private func handleInput(_ inBuffer: AVAudioPCMBuffer) {
        guard let converter, let procFormat else { return }
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
        try? fullFile?.write(from: buf)
    }

    /// Re-transcribe a whole saved recording (batch path, e.g. the row "Transcribe" button).
    func transcribe(recording url: URL) {
        guard !isTranscribing, !isRecording else { return }
        lastRecordingURL = url
        Task { [weak self] in await self?.batchTranscribe(url, source: .inApp) }
    }

    @MainActor
    private func batchTranscribe(_ url: URL, source: ASRTranscriptionSource) async -> String? {
        isTranscribing = true
        status = "Transcribing…"
        let text = await transcribeFile(url)
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

    // MARK: Recordings library

    func refreshRecordings() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: recordingsDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        recordings = files
            .filter { $0.pathExtension.lowercased() == "wav" }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let duration = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
                return VoiceRecording(url: url, date: date, duration: duration, hasTranscript: hasTranscript(for: url))
            }
            .sorted { $0.date > $1.date }
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
        recordings
            .compactMap { rec -> String? in
                let t = transcript(for: rec.url)
                guard !t.isEmpty else { return nil }
                return "\(rec.date.formatted(date: .abbreviated, time: .shortened))\n\(t)"
            }
            .joined(separator: "\n\n———\n\n")
    }

    var hasAnyTranscript: Bool { recordings.contains { $0.hasTranscript } }

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

    // MARK: Transcription

    /// POST one WAV to the warm server and return its transcript (nil on error).
    /// Used for both new recordings and saved-file re-transcription.
    private func transcribeFile(_ audioURL: URL) async -> String? {
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

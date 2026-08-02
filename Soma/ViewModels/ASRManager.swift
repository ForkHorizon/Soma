import AppKit
import AVFoundation
import Combine
import Foundation
import Network
import SwiftUI

struct RecordingIndexEntry: Sendable {
    let url: URL
    let date: Date
    let hasTranscript: Bool
}

struct QueuedTranscription {
    let url: URL
    let source: ASRTranscriptionSource
    let chunkPipeline: VoiceChunkPipeline?
    let expectedChunkCount: Int
    let continuation: CheckedContinuation<String?, Never>
}

struct VoiceServerErrorEnvelope: Decodable {
    let error: VoiceServerErrorDetail?
}

struct VoiceServerErrorDetail: Decodable {
    let code: String?
    let message: String?
    let retryable: Bool?
}

struct VoiceServerRemoteError: LocalizedError {
    let code: String
    let message: String
    let retryable: Bool

    var errorDescription: String? { message }
}

struct VoiceServerJobResponse: Decodable {
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
    @Published var lastRecordingURL: URL?  // persisted; survives a failed transcription
    @Published var playingURL: URL?  // which recording is currently playing
    @Published var recordings: [VoiceRecording] = []
    @Published var recordingsTotal = 0
    @Published var completedTranscriptionID = 0  // bumped when a recording is FULLY transcribed (final)
    @Published var lastTranscriptionSource: ASRTranscriptionSource = .inApp
    @Published var voiceServerConnectionState: VoiceServerConnectionState = .unknown
    @Published var voiceServerStatusDetail = "Not checked"
    @Published var importJobs: [MediaImportJob] = []
    @Published var importHistory: [MediaImportHistory] = []

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
            teardownServer()  // next transcription relaunches with the new engine
            status = "Engine: \(engineTitle)"
        }
    }
    static let engines: [(id: String, title: String)] = [
        ("whisper", "Whisper large-v3"),
        ("gigaam", "GigaAM v2 (Russian)"),
    ]
    var engineTitle: String { Self.engines.first { $0.id == engine }?.title ?? engine }
    var enginesRoot: String {
        UserDefaults.standard.string(forKey: "asrEnginesRoot") ?? "/Users/daliys/Daliys/AI_Test_PlayGround/asr-engines"
    }
    var modelsRoot: String {
        (enginesRoot as NSString).deletingLastPathComponent + "/asr-models"
    }
    var keepLoadedMinutes: Int {
        UserDefaults.standard.object(forKey: "modelKeepLoadedMinutes") as? Int ?? 15
    }
    var backend: String {
        UserDefaults.standard.string(forKey: "asrBackend") ?? "local"
    }
    var usesRemoteServer: Bool { backend == "remote" }
    var voiceServerURL: URL? {
        let raw = (UserDefaults.standard.string(forKey: "voiceServerURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let normalized = raw.contains("://") ? raw : "https://\(raw)"
        guard let url = URL(string: normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            url.scheme?.lowercased() == "https"
        else { return nil }
        return url
    }
    var voiceServerURLProblem: String {
        let raw = (UserDefaults.standard.string(forKey: "voiceServerURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "Server URL is empty" }
        return "Server URL must use HTTPS (configure Tailscale Serve first)"
    }
    var voiceServerToken: String {
        VoiceServerTokenStore.load()
    }
    var remoteCapabilityConfigIdentity: String {
        "\(voiceServerURL?.absoluteString ?? "")|\(engine)"
    }
    var voiceServerClientID: String {
        let key = "voiceServerClientID"
        if let existing = UserDefaults.standard.string(forKey: key),
            existing.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil
        {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    var port: Int?  // discovered at runtime (OS-assigned, no collisions)
    var serverProcess: Process?
    var activeRecordingURL: URL?
    var recordingStartToken = 0
    var player: AVAudioPlayer?
    var playbackResetTask: Task<Void, Never>?
    let portFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("soma_asr.port")
    let logFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("soma_asr_server.log")

    // Mic audio is captured via AVAudioEngine, converted to 16 kHz mono, then written
    // to one WAV. Transcription runs after stop; saved audio survives failures.
    var engineNode = AVAudioEngine()
    var converter: AVAudioConverter?
    var procFormat: AVAudioFormat?
    var fullFile: AVAudioFile?
    var activeChunkCapture: VoiceChunkCapture?
    var activeChunkPipeline: VoiceChunkPipeline?
    var remoteChunkCapability: Bool?
    var remoteCapabilityIdentity = ""
    var recordingBeganAt: Date?
    var receivedAudioSignal = false
    let audioQueue = DispatchQueue(label: "soma.asr.audio")
    let targetSampleRate = 16000.0
    let initialRecordingsLimit = 5
    let recordingsPageSize = 20
    var recordingIndex: [RecordingIndexEntry] = []
    var importQueueTask: Task<Void, Never>?
    var activeImportID: UUID?
    var cancelledImportIDs = Set<UUID>()
    weak var textPriorityQueue: VoiceTextPriorityQueue?
    var queuedTranscriptions: [QueuedTranscription] = []
    var transcriptionQueueTask: Task<Void, Never>?
    let connectivityMonitor = NWPathMonitor()
    let connectivityMonitorQueue = DispatchQueue(label: "soma.media-import.connectivity")

    // Recordings persist here (not /tmp) so a failed transcription never loses the take.
    lazy var recordingsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soma/VoiceRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    lazy var importsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soma/MediaImports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("History", isDirectory: true), withIntermediateDirectories: true)
        return dir
    }()

    var importQueueURL: URL { importsDir.appendingPathComponent("queue.json") }
    var importHistoryURL: URL { importsDir.appendingPathComponent("history.json") }

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
    func migrateVoiceModelRetentionToFifteenMinutes() {
        let migrationKey = "voiceModelRetentionFifteenMinMigrationV1"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        UserDefaults.standard.set(15, forKey: "modelKeepLoadedMinutes")
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    /// Free the local ASR model when the OS reports memory pressure and nothing
    /// is in flight, so Soma can't be the process that tips a tight box into
    /// swap thrash. Remote mode has no local model, so this is a no-op there.
    var memoryPressureSource: DispatchSourceMemoryPressure?
    func installMemoryPressureUnload() {
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

}

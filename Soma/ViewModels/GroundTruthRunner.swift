import Combine
import Foundation

struct GroundTruthVerdict: Identifiable, Hashable {
    let file: String
    let status: String
    let reason: String
    let edits: Int
    var id: String { file }

    var isReview: Bool { status == "review" }
}

/// Drives Scripts/ground_truth_build.py and mirrors its JSONL progress into
/// published state.
///
/// The run is hours long, so nothing lives only in memory: the script appends
/// every decode and every verdict to disk and skips finished files on restart.
/// Closing the app loses the child process, not the work.
@MainActor
final class GroundTruthRunner: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var stage = "Idle"
    @Published private(set) var currentFile = ""
    @Published private(set) var files = 0
    @Published private(set) var decided = 0
    @Published private(set) var accepted = 0
    @Published private(set) var review = 0
    @Published private(set) var errors = 0
    @Published private(set) var empty = 0
    @Published private(set) var failure: String?
    @Published private(set) var verdicts: [GroundTruthVerdict] = []

    private var process: Process?
    private var buffer = ""

    var progress: Double { files > 0 ? Double(decided) / Double(files) : 0 }
    var remaining: Int { max(0, files - decided) }

    /// Cheapest review cases first: most disagreements come down to one or two
    /// words, and clearing those first is what makes the queue finishable.
    var reviewQueue: [GroundTruthVerdict] {
        verdicts.filter(\.isReview).sorted { ($0.edits, $0.file) < ($1.edits, $1.file) }
    }

    static var outputDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soma/GroundTruth", isDirectory: true)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // ViewModels
            .deletingLastPathComponent()      // Soma
            .deletingLastPathComponent()      // repo root
    }

    private var pythonPath: String {
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3")
            ? "/opt/homebrew/bin/python3" : "/usr/bin/python3"
    }

    // MARK: Reading what a previous run already decided

    func loadExistingVerdicts() {
        let url = Self.outputDirectory.appendingPathComponent("verdicts.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        verdicts = text.split(separator: "\n").compactMap(Self.verdict(fromLine:))
        recount()
        if !isRunning, decided > 0 {
            stage = "Loaded \(decided) verdicts from the last run"
        }
    }

    private static func verdict(fromLine line: Substring) -> GroundTruthVerdict? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let file = object["file"] as? String,
              let status = object["status"] as? String
        else { return nil }
        return GroundTruthVerdict(file: file, status: status,
                                  reason: object["reason"] as? String ?? "",
                                  edits: object["edits"] as? Int ?? 0)
    }

    private func recount() {
        decided = verdicts.count
        accepted = verdicts.filter { $0.status == "accepted" }.count
        review = verdicts.filter { $0.status == "review" }.count
        errors = verdicts.filter { $0.status == "error" }.count
        empty = verdicts.filter { $0.status == "empty" }.count
        files = max(files, decided)
    }

    // MARK: Running

    func start(asr: ASRManager, bestOf: Int) {
        guard !isRunning else { return }
        failure = nil
        loadExistingVerdicts()
        let script = repoRoot.appendingPathComponent("Scripts/ground_truth_build.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            failure = "ground_truth_build.py not found at \(script.path)"
            return
        }
        try? FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        do {
            try launch(script: script, asr: asr, bestOf: bestOf)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func launch(script: URL, asr: ASRManager, bestOf: Int) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = [
            script.path,
            "--recordings", asr.recordingsDir.path,
            "--out", Self.outputDirectory.path,
            "--engines-root", asr.enginesRoot,
            "--models-root", asr.modelsRoot,
            "--best-of", String(bestOf),
        ]
        task.currentDirectoryURL = repoRoot
        task.environment = childEnvironment()

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in self?.absorb(chunk) }
        }
        task.terminationHandler = { _ in
            Task { @MainActor [weak self] in self?.finish() }
        }
        try task.run()
        process = task
        isRunning = true
        stage = "Starting…"
    }

    /// Mirrors ASRManager+LocalServer: Xcode's Metal validation vars abort the
    /// torch/MPS child, and a Finder-launched app has no Homebrew on PATH.
    private func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["METAL_DEVICE_WRAPPER_TYPE", "METAL_DEBUG_ERROR_MODE", "METAL_ERROR_MODE",
                    "MTL_DEBUG_LAYER", "MTL_SHADER_VALIDATION"] {
            environment.removeValue(forKey: key)
        }
        let base = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + base
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    func stop() {
        process?.terminate()
        process = nil
        isRunning = false
        stage = "Stopped — rerun resumes where this left off"
    }

    private func finish() {
        guard isRunning else { return }
        process = nil
        isRunning = false
        stage = remaining == 0 ? "Finished" : "Ended early — rerun resumes where this left off"
    }

    // MARK: Progress events

    private func absorb(_ chunk: String) {
        buffer += chunk
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            handle(line)
        }
    }

    private func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = event["event"] as? String
        else { return }
        switch name {
        case "plan":
            files = event["files"] as? Int ?? files
            stage = "\(event["pending"] as? Int ?? 0) recordings still to decide"
        case "stage":
            stage = event["text"] as? String ?? stage
        case "decode":
            currentFile = "\(event["file"] as? String ?? "") · \(event["config"] as? String ?? "")"
        case "verdict":
            appendVerdict(event)
        case "totals", "done":
            applyTotals(event)
        case "fatal":
            failure = "\(event["config"] as? String ?? "engine"): \(event["error"] as? String ?? "failed to load")"
        default:
            break
        }
    }

    private func appendVerdict(_ event: [String: Any]) {
        guard let file = event["file"] as? String, let status = event["status"] as? String else { return }
        verdicts.removeAll { $0.file == file }
        verdicts.append(GroundTruthVerdict(file: file, status: status,
                                           reason: event["reason"] as? String ?? "",
                                           edits: event["edits"] as? Int ?? 0))
    }

    private func applyTotals(_ event: [String: Any]) {
        files = event["files"] as? Int ?? files
        decided = event["decided"] as? Int ?? decided
        accepted = event["accepted"] as? Int ?? accepted
        review = event["review"] as? Int ?? review
        errors = event["error"] as? Int ?? errors
        empty = event["empty"] as? Int ?? empty
    }
}

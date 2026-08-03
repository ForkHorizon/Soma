import Combine
import Foundation

struct GroundTruthVerdict: Identifiable, Hashable {
    let file: String
    let status: String
    let reason: String
    let edits: Int
    /// Every engine's text for this recording, so the listener can compare them
    /// without the panel having to re-run anything.
    let candidates: [String: String]
    /// Cross-script pairs this file would need confirmed before the engines
    /// could agree — proposals only, never applied on their own.
    let terms: [TermPair]
    /// One clip per disputed word cluster, from the tier-one decode's word
    /// timestamps. Empty means nothing narrower than the whole recording.
    let spots: [ClosedRange<Double>]
    var id: String { file }

    var isReview: Bool { status == "review" }
}

struct TermPair: Identifiable, Hashable {
    let heard: String        // what GigaAM wrote
    let written: String      // what Whisper wrote
    var id: String { "\(heard)→\(written)" }
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
    /// Last few non-JSON lines from the child, so a failure can say what broke.
    private var diagnostics: [String] = []

    var progress: Double { files > 0 ? Double(decided) / Double(files) : 0 }
    var remaining: Int { max(0, files - decided) }

    var reviewQueue: [GroundTruthVerdict] { Self.stratified(verdicts.filter(\.isReview)) }

    /// Rounds of one file from each difficulty band, easiest first within a
    /// round.
    ///
    /// Sorting purely by cost put all 200 one-and-two-word cases at the top,
    /// so working down the list built a sample of nothing but easy recordings —
    /// and easy recordings are where every decode configuration looks alike.
    /// The queue exists to measure those configurations against each other, so
    /// it has to stay representative at whatever point the listener stops,
    /// which is the realistic outcome: 589 files is hours, and roughly 200 is
    /// already enough for the interval this measurement needs.
    nonisolated static func stratified(_ items: [GroundTruthVerdict]) -> [GroundTruthVerdict] {
        let bands = Dictionary(grouping: items) { band($0.edits) }
            .sorted { $0.key < $1.key }
            .map { $0.value.sorted { ($0.edits, $0.file) < ($1.edits, $1.file) } }
        var mixed: [GroundTruthVerdict] = []
        var depth = 0
        while mixed.count < items.count {
            for band in bands where depth < band.count { mixed.append(band[depth]) }
            depth += 1
        }
        return mixed
    }

    nonisolated static func band(_ edits: Int) -> Int {
        switch edits {
        case ...1: return 0
        case 2: return 1
        case 3...5: return 2
        case 6...10: return 3
        default: return 4
        }
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
        let pairs = (object["terms"] as? [[String]] ?? []).compactMap { pair -> TermPair? in
            pair.count == 2 ? TermPair(heard: pair[0], written: pair[1]) : nil
        }
        return GroundTruthVerdict(file: file, status: status,
                                  reason: object["reason"] as? String ?? "",
                                  edits: object["edits"] as? Int ?? 0,
                                  candidates: object["candidates"] as? [String: String] ?? [:],
                                  terms: pairs, spots: Self.spots(object["spot_seconds"]))
    }

    private static func spots(_ raw: Any?) -> [ClosedRange<Double>] {
        (raw as? [[Double]] ?? []).compactMap { pair in
            guard pair.count == 2, pair[1] > pair[0] else { return nil }
            return pair[0]...pair[1]
        }
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

    /// Re-votes every cached decode under the current glossary. No model runs,
    /// so confirming a term and seeing the queue shrink takes seconds — that is
    /// the whole reason each decode is kept on disk.
    func reAdjudicate(asr: ASRManager) {
        start(asr: asr, bestOf: 1, adjudicateOnly: true)
    }

    func start(asr: ASRManager, bestOf: Int, thorough: Bool = false, adjudicateOnly: Bool = false) {
        guard !isRunning else { return }
        failure = nil
        diagnostics = []
        loadExistingVerdicts()
        let script = repoRoot.appendingPathComponent("Scripts/ground_truth_build.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            failure = "ground_truth_build.py not found at \(script.path)"
            return
        }
        try? FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        do {
            try launch(script: script, asr: asr, bestOf: bestOf, thorough: thorough, adjudicateOnly: adjudicateOnly)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func launch(script: URL, asr: ASRManager, bestOf: Int, thorough: Bool, adjudicateOnly: Bool) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = [
            script.path,
            "--recordings", asr.recordingsDir.path,
            "--out", Self.outputDirectory.path,
            "--engines-root", asr.enginesRoot,
            "--models-root", asr.modelsRoot,
            "--best-of", String(bestOf),
        ] + (adjudicateOnly ? ["--adjudicate-only"] : []) + (thorough ? ["--thorough"] : [])
        task.currentDirectoryURL = repoRoot
        task.environment = childEnvironment()

        let pipe = Pipe()
        task.standardOutput = pipe
        // The child merges its own stderr into stdout, so a crash arrives on the
        // same stream as progress. Discarding it here is what let a Python
        // syntax, path or permission failure report "Finished".
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in self?.absorb(chunk) }
        }
        task.terminationHandler = { finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in self?.finish(status: status) }
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

    /// A run that exits non-zero has NOT finished, however the counters look.
    /// Basing the message on those alone reported success for a child that never
    /// decoded anything.
    private func finish(status: Int32) {
        guard isRunning else { return }
        process = nil
        isRunning = false
        loadExistingVerdicts()   // picks up candidates and term proposals for the review queue
        if status != 0 {
            let tail = diagnostics.suffix(3).joined(separator: " | ")
            failure = "the run exited with status \(status)" + (tail.isEmpty ? "" : ": \(tail)")
            stage = "Failed — nothing was lost; a rerun resumes from the last verdict"
            return
        }
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
        else {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { diagnostics = (diagnostics + [String(text.prefix(200))]).suffix(10) }
            return
        }
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
                                           edits: event["edits"] as? Int ?? 0,
                                           candidates: [:], terms: [], spots: []))
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

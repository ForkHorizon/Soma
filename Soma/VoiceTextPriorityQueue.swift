import Combine
import Foundation

enum VoiceTextWorkPhase {
    case translating
    case buildingPrompt
}

/// One shared DeepSeek lane for voice work. Live dictation is always selected
/// before the next media segment; a segment already in flight is allowed to
/// finish so we never duplicate or lose text.
@MainActor
final class VoiceTextPriorityQueue: ObservableObject {
    private enum BackgroundState: String, Codable {
        case queued
        case running
        case failed
    }

    private struct BackgroundJob: Identifiable, Codable {
        let id: UUID
        let importID: UUID
        let index: Int
        let total: Int
        let text: String
        let outputPath: String
        let finalOutputPath: String
        var state: BackgroundState
        var errorMessage: String?
    }

    private struct InteractiveJob {
        let text: String
        let mode: VoiceOutputMode
        let onPhase: ((VoiceTextWorkPhase) -> Void)?
        let continuation: CheckedContinuation<String, Error>
    }

    @Published private(set) var activeDescription = "Idle"
    @Published private(set) var pendingBackgroundCount = 0
    @Published private(set) var failedBackgroundImportIDs: [UUID] = []

    private weak var somaViewModel: SomaViewModel?
    private weak var ollama: OllamaManager?
    private weak var prompter: RusToPromptViewModel?
    private var interactiveJobs: [InteractiveJob] = []
    private var backgroundJobs: [BackgroundJob] = []
    private var runner: Task<Void, Never>?

    /// Called after all translated fragments have been joined in strict order.
    var onImportTranslationCompleted: ((UUID, URL) -> Void)?

    private let queueURL: URL

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Soma/MediaImports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queueURL = directory.appendingPathComponent("translation-queue.json")
        restore()
        pendingBackgroundCount = backgroundJobs.filter { $0.state != .failed }.count
    }

    func configure(somaViewModel: SomaViewModel, ollama: OllamaManager, prompter: RusToPromptViewModel) {
        self.somaViewModel = somaViewModel
        self.ollama = ollama
        self.prompter = prompter
        // An app termination cannot leave a request alive. Resume persisted work
        // at the next segment rather than treating it as permanently active.
        for index in backgroundJobs.indices where backgroundJobs[index].state == .running {
            backgroundJobs[index].state = .queued
        }
        persist()
        startNextIfNeeded()
    }

    func translateInteractive(_ text: String, mode: VoiceOutputMode, onPhase: ((VoiceTextWorkPhase) -> Void)? = nil) async throws -> String {
        guard mode != .original else { return text }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }
        return try await withCheckedThrowingContinuation { continuation in
            interactiveJobs.append(InteractiveJob(text: clean, mode: mode, onPhase: onPhase, continuation: continuation))
            startNextIfNeeded()
        }
    }

    func enqueueBackgroundTranslation(importID: UUID, transcript: String, destination: URL) {
        let parts = Self.splitForTranslation(transcript)
        guard !parts.isEmpty else {
            do {
                try "".write(to: destination, atomically: true, encoding: .utf8)
                onImportTranslationCompleted?(importID, destination)
            } catch {
                activeDescription = "Could not save imported translation: \(error.localizedDescription)"
            }
            return
        }
        // Avoid enqueueing the same restored import twice.
        guard !backgroundJobs.contains(where: { $0.importID == importID }) else { return }
        for (index, part) in parts.enumerated() {
            backgroundJobs.append(BackgroundJob(
                id: UUID(), importID: importID, index: index, total: parts.count,
                text: part,
                outputPath: destination.deletingPathExtension().appendingPathExtension("part-\(index).txt").path,
                finalOutputPath: destination.path,
                state: .queued,
                errorMessage: nil
            ))
        }
        persist()
        refreshCount()
        startNextIfNeeded()
    }

    func retryFailedBackgroundTranslation(importID: UUID) {
        for index in backgroundJobs.indices where backgroundJobs[index].importID == importID && backgroundJobs[index].state == .failed {
            backgroundJobs[index].state = .queued
            backgroundJobs[index].errorMessage = nil
        }
        persist()
        refreshCount()
        startNextIfNeeded()
    }

    func cancelBackgroundTranslation(importID: UUID) {
        let canceled = backgroundJobs.filter { $0.importID == importID }
        backgroundJobs.removeAll { $0.importID == importID }
        for job in canceled {
            try? FileManager.default.removeItem(atPath: job.outputPath)
        }
        persist()
        refreshCount()
    }

    private func startNextIfNeeded() {
        guard runner == nil, somaViewModel != nil, ollama != nil, prompter != nil else { return }
        if let live = interactiveJobs.first {
            interactiveJobs.removeFirst()
            runner = Task { [weak self] in await self?.run(live) }
        } else if let index = backgroundJobs.firstIndex(where: { $0.state == .queued }) {
            backgroundJobs[index].state = .running
            persist()
            refreshCount()
            let job = backgroundJobs[index]
            runner = Task { [weak self] in await self?.run(job) }
        } else {
            activeDescription = "Idle"
        }
    }

    private func run(_ job: InteractiveJob) async {
        defer {
            runner = nil
            startNextIfNeeded()
        }
        do {
            activeDescription = "Translating live text"
            let output = try await translate(job.text, mode: job.mode, updatesPrompter: true, onPhase: job.onPhase)
            job.continuation.resume(returning: output)
        } catch {
            if let prompter, let ollama {
                prompter.errorMessage = error.localizedDescription
                prompter.phase = .failed
                ollama.checkStatus()
            }
            job.continuation.resume(throwing: error)
        }
    }

    private func run(_ job: BackgroundJob) async {
        defer {
            runner = nil
            startNextIfNeeded()
        }
        do {
            activeDescription = "Translating imported media \(job.index + 1)/\(job.total)"
            let output = try await translate(job.text, mode: .english, updatesPrompter: false)
            try output.write(to: URL(fileURLWithPath: job.outputPath), atomically: true, encoding: .utf8)
            try markBackgroundComplete(job)
        } catch {
            guard let index = backgroundJobs.firstIndex(where: { $0.id == job.id }) else { return }
            backgroundJobs[index].state = .failed
            backgroundJobs[index].errorMessage = error.localizedDescription
            persist()
            refreshCount()
        }
    }

    private func translate(_ text: String, mode: VoiceOutputMode, updatesPrompter: Bool, onPhase: ((VoiceTextWorkPhase) -> Void)? = nil) async throws -> String {
        guard let somaViewModel, let ollama, let prompter else { throw SomaError("Translation service is unavailable.") }
        if updatesPrompter {
            prompter.inputPrompt = text
            prompter.resetRunState()
            prompter.phase = .translating
        }
        onPhase?(.translating)
        let translated = try await somaViewModel.runRusToPromptTranslate(prompt: text, translatorModel: prompter.translatorModel)
        let translatedText = translated.translation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard translated.status == "ok", !translatedText.isEmpty else {
            throw SomaError(translated.warningSummary)
        }
        if updatesPrompter {
            _ = await prompter.applyTranslationResult(translated, translatedText: translatedText, ollama: ollama)
        }
        guard mode == .prompt else {
            if updatesPrompter { prompter.phase = .done; ollama.checkStatus() }
            return translatedText
        }
        if updatesPrompter { prompter.phase = .analyzing }
        onPhase?(.buildingPrompt)
        let improved = try await somaViewModel.runRusToPromptImprove(prompt: translatedText, analyzerModel: prompter.analyzerModel)
        guard !improved.promptForCopy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SomaError(improved.warningSummary)
        }
        if updatesPrompter {
            await prompter.applyImprovementResult(improved, sourcePrompt: text, ollama: ollama, queueManager: nil)
        }
        return improved.promptForCopy
    }

    private func markBackgroundComplete(_ job: BackgroundJob) throws {
        guard let index = backgroundJobs.firstIndex(where: { $0.id == job.id }) else { return }
        let siblings = backgroundJobs.filter { $0.importID == job.importID && $0.id != job.id }
        if siblings.isEmpty {
            let partURLs = (0..<job.total).map {
                URL(fileURLWithPath: job.finalOutputPath)
                    .deletingPathExtension()
                    .appendingPathExtension("part-\($0).txt")
            }
            let joined = try partURLs.map { try String(contentsOf: $0, encoding: .utf8) }
                .joined(separator: "\n\n")
            let destination = URL(fileURLWithPath: job.finalOutputPath)
            try joined.write(to: destination, atomically: true, encoding: .utf8)
            for url in partURLs { try? FileManager.default.removeItem(at: url) }
            onImportTranslationCompleted?(job.importID, destination)
        }
        backgroundJobs.remove(at: index)
        persist()
        refreshCount()
    }

    private func restore() {
        guard let data = try? Data(contentsOf: queueURL), let decoded = try? JSONDecoder().decode([BackgroundJob].self, from: data) else { return }
        backgroundJobs = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(backgroundJobs) else { return }
        try? data.write(to: queueURL, options: .atomic)
    }

    private func refreshCount() {
        pendingBackgroundCount = backgroundJobs.filter { $0.state != .failed }.count
        failedBackgroundImportIDs = Array(Set(
            backgroundJobs.filter { $0.state == .failed }.map(\.importID)
        )).sorted { $0.uuidString < $1.uuidString }
    }

    static func splitForTranslation(_ text: String, limit: Int = 2_500) -> [String] {
        guard limit > 0 else { return [] }
        let characters = Array(text)
        var result: [String] = []
        var start = 0
        while start < characters.count {
            var end = min(start + limit, characters.count)
            if end < characters.count {
                let preferredStart = max(start, end - min(400, limit))
                if let boundary = stride(from: end - 1, through: preferredStart, by: -1).first(where: {
                    characters[$0].isWhitespace || ".!?".contains(characters[$0])
                }) {
                    end = boundary + 1
                }
            }
            let part = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { result.append(part) }
            start = end
        }
        return result
    }
}

import AppKit
import AVFoundation
import Foundation

extension ASRManager {
    // MARK: Recordings library

    /// Retention: drop saved recordings (and their transcripts) older than the
    /// configured window so the VoiceRecordings cache can't grow without bound.
    /// Runs at launch and again whenever the setting changes, off the main thread.
    static let retentionKey = "recordingRetentionDays"
    static let defaultRetentionDays = 90
    static var retentionDays: Int {
        UserDefaults.standard.object(forKey: retentionKey) as? Int ?? defaultRetentionDays
    }

    /// ponytail: 0 days means keep forever, so the sweep needs no separate
    /// on/off toggle. Split out from the sweep itself to stay testable.
    nonisolated static func retentionCutoff(days: Int, now: Date = Date()) -> Date? {
        days > 0 ? now.addingTimeInterval(-Double(days) * 24 * 60 * 60) : nil
    }

    func pruneOldRecordings() {
        let dir = recordingsDir
        guard let cutoff = Self.retentionCutoff(days: Self.retentionDays) else {
            refreshRecordings()
            return
        }
        Task { [weak self, dir, cutoff] in
            await Task.detached(priority: .utility) {
                Self.removeRecordingFiles(in: dir, olderThan: cutoff)
            }.value
            self?.refreshRecordings()
        }
    }

    nonisolated static func removeRecordingFiles(in dir: URL, olderThan cutoff: Date) {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        for url in files where url.pathExtension.lowercased() == "wav" {
            // An unreadable date used to fall back to .distantPast, which made
            // "I don't know how old this is" mean "delete it". Unknown age is a
            // reason to keep a recording, not to destroy it.
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                date < cutoff
            else { continue }
            // The transcript goes only once its audio is actually gone. Removing
            // it after a failed WAV delete would leave a recording nothing can
            // read back.
            guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("txt"))
        }
    }

    func refreshRecordings() {
        // Keep one cancellable library refresh. The directory listing still
        // reconciles external changes, while cached durations avoid reopening
        // every unchanged WAV after each new recording.
        recordingsRefreshTask?.cancel()
        recordingsRefreshGeneration += 1
        let generation = recordingsRefreshGeneration
        let dir = recordingsDir
        if recordingDurationCacheDirectory != dir {
            recordingDurationCache.removeAll(keepingCapacity: true)
            recordingDurationCacheDirectory = dir
        }
        let cache = recordingDurationCache

        recordingsRefreshTask = Task.detached(priority: .utility) { [weak self] in
            guard let snapshot = Self.buildRecordingLibrarySnapshot(at: dir, cache: cache),
                !Task.isCancelled
            else { return }
            await MainActor.run { [weak self] in
                guard let self, self.recordingsRefreshGeneration == generation else { return }
                self.recordingDurationCache = snapshot.durationCache
                self.recordingIndex = snapshot.index
                self.recordingsTotal = snapshot.index.count
                self.totalAudioDuration = snapshot.totalDuration
                self.recordings = []
                self.loadMoreRecordings(limit: self.initialRecordingsLimit)
                self.recordingsRefreshTask = nil
            }
        }
    }

    private struct RecordingLibrarySnapshot: Sendable {
        let index: [RecordingIndexEntry]
        let durationCache: [String: RecordingDurationCacheEntry]
        let totalDuration: TimeInterval
    }

    nonisolated private static func buildRecordingLibrarySnapshot(
        at dir: URL,
        cache: [String: RecordingDurationCacheEntry]
    ) -> RecordingLibrarySnapshot? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var updatedCache: [String: RecordingDurationCacheEntry] = [:]
        var index: [RecordingIndexEntry] = []
        var totalDuration = 0.0

        for url in files where url.pathExtension.lowercased() == "wav" {
            guard !Task.isCancelled else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let date = values?.contentModificationDate ?? .distantPast
            let fileSize = Int64(values?.fileSize ?? -1)
            let key = url.path
            let duration: TimeInterval
            if let cached = cache[key],
                cached.fileSize == fileSize,
                cached.modificationDate == date
            {
                duration = cached.duration
            } else {
                duration = audioDuration(for: url)
            }
            updatedCache[key] = RecordingDurationCacheEntry(
                fileSize: fileSize,
                modificationDate: date,
                duration: duration
            )
            totalDuration += duration
            let transcript = url.deletingPathExtension().appendingPathExtension("txt")
            index.append(
                RecordingIndexEntry(
                    url: url,
                    date: date,
                    duration: duration,
                    hasTranscript: FileManager.default.fileExists(atPath: transcript.path)
                ))
        }

        index.sort { $0.date > $1.date }
        return RecordingLibrarySnapshot(
            index: index,
            durationCache: updatedCache,
            totalDuration: totalDuration
        )
    }

    nonisolated private static func audioDuration(for url: URL) -> TimeInterval {
        guard let audio = try? AVAudioFile(forReading: url),
            audio.processingFormat.sampleRate > 0
        else { return 0 }
        return Double(audio.length) / audio.processingFormat.sampleRate
    }

    var hasMoreRecordings: Bool { recordings.count < recordingsTotal }

    var nextRecordingsPageSize: Int {
        min(recordingsPageSize, max(recordingsTotal - recordings.count, 0))
    }

    func loadMoreRecordings() {
        loadMoreRecordings(limit: recordingsPageSize)
    }

    func loadMoreRecordings(limit: Int) {
        let nextEntries = recordingIndex.dropFirst(recordings.count).prefix(limit)
        guard !nextEntries.isEmpty else { return }
        recordings.append(
            contentsOf: nextEntries.map { entry in
                return VoiceRecording(
                    url: entry.url,
                    date: entry.date,
                    duration: entry.duration,
                    hasTranscript: entry.hasTranscript
                )
            })
    }

    func transcriptURL(for wav: URL) -> URL {
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

}

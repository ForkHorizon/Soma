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
        guard let cutoff = Self.retentionCutoff(days: Self.retentionDays) else { return }
        let dir = recordingsDir
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
            let files =
                (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            let index =
                files
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

    func loadMoreRecordings(limit: Int) {
        let nextEntries = recordingIndex.dropFirst(recordings.count).prefix(limit)
        guard !nextEntries.isEmpty else { return }
        recordings.append(
            contentsOf: nextEntries.map { entry in
                let duration = (try? AVAudioPlayer(contentsOf: entry.url))?.duration ?? 0
                return VoiceRecording(
                    url: entry.url,
                    date: entry.date,
                    duration: duration,
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

    // MARK: Playback

    func togglePlayback(_ url: URL) {
        togglePlayback(url, from: nil, to: nil)
    }

    /// Playing a range matters for review: one wrong word in a two-minute
    /// recording otherwise costs a full listen to check.
    func togglePlayback(_ url: URL, from start: Double?, to end: Double?) {
        if playingURL == url { stopPlayback(); return }
        stopPlayback()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            player = p
            let begin = min(max(start ?? 0, 0), max(p.duration - 0.05, 0))
            p.currentTime = begin
            p.play()
            playingURL = url
            // No delegate — just clear the flag when the clip's duration elapses.
            let window = min(end ?? p.duration, p.duration) - begin
            playbackResetTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(window, 0.1) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.stopPlayback()
            }
        } catch {
            status = "Playback error: \(error.localizedDescription)"
        }
    }

    func stopPlayback() {
        playbackResetTask?.cancel()
        playbackResetTask = nil
        player?.stop()
        player = nil
        playingURL = nil
    }
}

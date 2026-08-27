import SwiftUI

/// Human audit for the separate Stage-8 auto-gold sample. This never promotes
/// rows to main gold: it only records whether the proposed text matches audio.
struct Stage8AuditView: View {
    @ObservedObject var asr: ASRManager
    @StateObject private var store: Stage8AuditStore
    @StateObject private var punctuator = Stage7PunctuationSuggester()
    private let title: String
    private let showPunctuationSuggestion: Bool
    @State private var index = 0
    @State private var heardText = ""
    @State private var notes = ""
    @FocusState private var editingText: Bool

    init(
        asr: ASRManager, title: String = "Stage-8 consensus audit",
        manifest: String = "stage8-auto-audit-100.jsonl",
        decisions: String = "stage8-auto-audit-decisions.jsonl",
        showPunctuationSuggestion: Bool = false
    ) {
        self.asr = asr
        self.title = title
        self.showPunctuationSuggestion = showPunctuationSuggestion
        let directory = Stage8AuditStore.experimentsDirectory
        _store = StateObject(
            wrappedValue: Stage8AuditStore(
                manifestURL: directory.appendingPathComponent(manifest),
                decisionsURL: directory.appendingPathComponent(decisions)))
    }

    private var current: Stage8AuditSample? {
        let rows = store.pending
        guard !rows.isEmpty else { return nil }
        return rows[min(index, rows.count - 1)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let failure = store.failure {
                ContentUnavailableView("Stage-8 audit unavailable", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else if let sample = current {
                review(sample)
            } else {
                ContentUnavailableView(
                    "Audit complete", systemImage: "checkmark.seal",
                    description: Text("All \(store.reviewedCount) sampled recordings have a saved decision."))
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 440, alignment: .topLeading)
        .onAppear {
            store.load()
            prepareCurrent()
        }
        .onDisappear { asr.stopPlayback() }
    }

    private func review(_ sample: Stage8AuditSample) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2).bold()
                    Text("\(store.reviewedCount) / \(store.samples.count) checked · \(sample.tier) · \(sample.file)")
                        .font(.caption).monospaced().foregroundStyle(.secondary)
                }
                Spacer()
                Button("Replay", systemImage: "play.fill") { play(sample) }
            }
            .buttonStyle(.bordered)
            Text("Proposed transcript").font(.headline)
            Text(sample.proposedText).textSelection(.enabled)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 8))
            if showPunctuationSuggestion { suggestionControls(sample) }
            TextEditor(text: $heardText).font(.body).frame(minHeight: 100)
                .focused($editingText)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
            TextField("Optional note", text: $notes).textFieldStyle(.roundedBorder)
                .focused($editingText)
            HStack {
                Button("Matches audio") { save(sample, status: "accepted", text: sample.proposedText) }
                    .buttonStyle(.borderedProminent).keyboardShortcut("1", modifiers: [])
                Button("Save correction") { save(sample, status: "corrected", text: heardText) }
                    .buttonStyle(.bordered).disabled(heardText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut("2", modifiers: [])
                Button("Mark no speech") { save(sample, status: "no-speech", text: "") }
                    .buttonStyle(.bordered)
                Spacer()
                Text("1 = matches · 2 = correction · Space = replay").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            heardText = sample.proposedText
            notes = ""
            play(sample)
        }
        .onKeyPress(.space) {
            guard !editingText else { return .ignored }
            play(sample)
            return .handled
        }
    }

    private func suggestionControls(_ sample: Stage8AuditSample) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(punctuator.isLoading ? "Suggesting…" : "Suggest punctuation") {
                Task { await punctuator.suggest(for: sample.proposedText) }
            }
            .disabled(punctuator.isLoading)
            .controlSize(.small)
            if !punctuator.suggestion.isEmpty {
                Text("Suggested punctuation").font(.caption).foregroundStyle(.secondary)
                Text(punctuator.suggestion).textSelection(.enabled).padding(8)
                    .background(Color.blue.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 6))
                Button("Use suggestion") { heardText = punctuator.suggestion }.controlSize(.small)
            }
            if let failure = punctuator.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func play(_ sample: Stage8AuditSample) {
        let url = URL(fileURLWithPath: sample.audioPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        asr.togglePlayback(url)
    }

    private func save(_ sample: Stage8AuditSample, status: String, text: String) {
        asr.stopPlayback()
        store.record(sample, status: status, auditedText: text.trimmingCharacters(in: .whitespacesAndNewlines), notes: notes)
        index = 0
        prepareCurrent()
    }

    private func prepareCurrent() {
        guard let sample = current else { return }
        heardText = sample.proposedText
        notes = ""
    }
}

import SwiftUI

struct Layer1ReviewView: View {
    @ObservedObject var asr: ASRManager
    @ObservedObject var runner: Layer1GroundTruthRunner
    @Environment(\.dismiss) private var dismiss
    @State private var cursor = 0
    @State private var text = ""
    @State private var sourceModelID: String?
    @State private var loadedSegmentID: String?

    private var items: [Layer1Segment] { runner.reviewSegments }
    private var current: Layer1Segment? { items.indices.contains(cursor) ? items[cursor] : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Layer 1 human review").font(.title3.bold())
                Spacer()
                Text("\(min(cursor + 1, items.count)) / \(items.count)").font(.caption).monospacedDigit()
                Button("Done") {
                    asr.stopPlayback()
                    dismiss()
                }
            }
            if let segment = current {
                review(segment)
            } else {
                Text("All available segments are verified.").font(.headline)
                Text(
                    "Every segment still passed through a human decision; model agreement never auto-accepted a segment."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20).frame(minWidth: 820, minHeight: 620)
        .onAppear {
            restoreCursor()
            loadCurrent()
        }.onChange(of: cursor) { _, _ in loadCurrent() }
        .onDisappear { asr.stopPlayback() }
    }

    private func review(_ segment: Layer1Segment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            reviewHeader(segment)
            HStack {
                Button {
                    play(segment, context: false)
                } label: {
                    Label("Play segment", systemImage: "play.fill")
                }
                Button {
                    play(segment, context: true)
                } label: {
                    Label("Play ±1.5 s context", systemImage: "waveform")
                }
                Button {
                    playWhole(segment)
                } label: {
                    Label("Whole file", systemImage: "arrow.up.right.and.arrow.down.left")
                }
            }.buttonStyle(.bordered).controlSize(.small)
            Text("All model proposals").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(segment.proposalOrder, id: \.self) { modelID in
                        if let suggestion = segment.modelSuggestions[modelID] { proposal(suggestion) }
                    }
                }
            }.frame(maxHeight: 300)
            Divider()
            Text(
                "Human text — preserve every spoken word, repetition, filler, false start, and unfinished attempt."
            )
            .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body).frame(minHeight: 90)
                .padding(6).background(Color.primary.opacity(0.05)).clipShape(
                    RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("No speech") { save(segment, text: "", action: .noSpeech) }
                Button("Unclear") { save(segment, text: text, action: .unclear) }
                Spacer()
                Button("Previous") { cursor = max(cursor - 1, 0) }.disabled(cursor == 0)
                Button("Save and next") { saveCurrent(segment) }.buttonStyle(.borderedProminent)
                Button("Next") { cursor = min(cursor + 1, max(items.count - 1, 0)) }.disabled(
                    cursor >= items.count - 1)
            }
        }
    }

    private func reviewHeader(_ segment: Layer1Segment) -> some View {
        HStack {
            Text(
                URL(fileURLWithPath: runner.store.file(for: segment.audioID)?.path ?? "").lastPathComponent
            )
            .font(.caption).monospaced()
            Text("· \(segment.start, specifier: "%.2f")–\(segment.end, specifier: "%.2f") s")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Mark bad boundary") { runner.flagSegmentation(segment.id) }.font(.caption)
            if segment.segmentationNeedsReview {
                Text("boundary flagged").font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private func proposal(_ suggestion: Layer1ModelSuggestion) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.model).font(.caption.bold())
                if suggestion.status == .failed {
                    Text("FAILED: \(suggestion.error ?? "unknown error")").font(.caption).foregroundStyle(
                        .red)
                } else {
                    Text(suggestion.text?.isEmpty == false ? suggestion.text! : "(no speech returned)")
                        .font(.callout).textSelection(.enabled)
                }
            }
            Spacer()
            if let value = suggestion.text, suggestion.status == .completed {
                Button("Use") {
                    text = value
                    sourceModelID = suggestion.modelID
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(8).background(Color.primary.opacity(0.045)).clipShape(
            RoundedRectangle(cornerRadius: 7))
    }

    private func loadCurrent() {
        guard let segment = current else { return }
        guard loadedSegmentID != segment.id else { return }
        loadedSegmentID = segment.id
        text = segment.decision.text ?? ""
        sourceModelID = segment.decision.sourceModelID
        let url = URL(fileURLWithPath: runner.store.file(for: segment.audioID)?.path ?? "")
        if FileManager.default.fileExists(atPath: url.path) { play(segment, context: false) }
    }

    private func restoreCursor() {
        guard let resumeID = runner.resumeSegmentID,
            let index = items.firstIndex(where: { $0.id == resumeID })
        else { return }
        cursor = index
    }

    private func saveCurrent(_ segment: Layer1Segment) {
        let original = sourceModelID.flatMap { segment.modelSuggestions[$0]?.text }
        let action: Layer1HumanAction =
            sourceModelID == nil ? .manual : (original == text ? .selectedModel : .selectedAndEdited)
        save(segment, text: text, action: action)
    }

    private func save(_ segment: Layer1Segment, text: String, action: Layer1HumanAction) {
        runner.saveDecision(
            segmentID: segment.id, text: text, action: action,
            sourceModelID: action == .noSpeech ? nil : sourceModelID)
        if cursor >= items.count {
            cursor = max(0, items.count - 1)
        }
        loadedSegmentID = nil
        loadCurrent()
    }

    private func play(_ segment: Layer1Segment, context: Bool) {
        guard let path = runner.store.file(for: segment.audioID)?.path else { return }
        let duration = runner.store.file(for: segment.audioID)?.duration ?? segment.end
        let start = context ? max(0, segment.start - 1.5) : segment.start
        let end = context ? min(duration, segment.end + 1.5) : segment.end
        asr.togglePlayback(URL(fileURLWithPath: path), from: start, to: end)
    }

    private func playWhole(_ segment: Layer1Segment) {
        guard let path = runner.store.file(for: segment.audioID)?.path else { return }
        asr.togglePlayback(URL(fileURLWithPath: path))
    }
}

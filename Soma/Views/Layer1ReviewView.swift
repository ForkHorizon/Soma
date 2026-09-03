import SwiftUI

private struct Layer1ReviewContext {
    let before: [String]
    let after: [String]
}

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
                    Label("Play ±5 s context", systemImage: "waveform")
                }
            }.buttonStyle(.bordered).controlSize(.small)
            Text("All model proposals").font(.headline)
            Text("Only time-aligned snippets are shown here; full-file outputs are scored after review.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(proposalGroups(for: segment).enumerated()), id: \.offset) { item in
                        proposal(item.element)
                    }
                }
            }.frame(maxHeight: 300)
            Text("Context around this segment").font(.headline)
            contextPreview(segment)
            Divider()
            Text(
                "Current segment — preserve every spoken word, repetition, filler, false start, and unfinished attempt."
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
            if segment.segmentationNeedsReview {
                Button("Clear boundary flag") { runner.clearSegmentationFlag(segment.id) }
                    .font(.caption)
                Text("boundary flagged").font(.caption2).foregroundStyle(.orange)
            } else {
                Button("Mark bad boundary") { runner.flagSegmentation(segment.id) }.font(.caption)
            }
        }
    }

    private func proposalGroups(for segment: Layer1Segment) -> [[Layer1ModelSuggestion]] {
        var groups: [[Layer1ModelSuggestion]] = []
        for modelID in segment.proposalOrder {
            guard let suggestion = segment.modelSuggestions[modelID] else { continue }
            let key = suggestion.status == .completed ? reviewText(for: suggestion) : nil
            if let key,
                let index = groups.firstIndex(where: { group in
                    guard let first = group.first else { return false }
                    return first.status == .completed && reviewText(for: first) == key
                })
            {
                groups[index].append(suggestion)
            } else {
                groups.append([suggestion])
            }
        }
        return groups.enumerated().sorted {
            if $0.element.count != $1.element.count { return $0.element.count > $1.element.count }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    private func proposal(_ suggestions: [Layer1ModelSuggestion]) -> some View {
        let suggestion = suggestions[0]
        let value = reviewText(for: suggestion)
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestions.map(\.model).joined(separator: ", ")).font(.caption.bold())
                if suggestion.status == .failed {
                    Text("FAILED: \(suggestion.error ?? "unknown error")").font(.caption).foregroundStyle(
                        .red)
                } else {
                    Text(value.isEmpty ? "(no speech returned)" : value)
                        .font(.callout).textSelection(.enabled)
                }
            }
            Spacer()
            if suggestion.text != nil, suggestion.status == .completed {
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

    private func contextPreview(_ segment: Layer1Segment) -> some View {
        let context = reviewContext(for: segment)
        let focus = reviewText(for: segment)
        let before = context.before.isEmpty ? "" : context.before.joined(separator: " ") + " "
        let after = context.after.isEmpty ? "" : " " + context.after.joined(separator: " ")
        return Text(
            "\(Text(before).foregroundStyle(.secondary))\(Text(focus.isEmpty ? "(empty segment)" : focus))\(Text(after).foregroundStyle(.secondary))"
        )
        .font(.body)
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func reviewContext(for segment: Layer1Segment) -> Layer1ReviewContext {
        let ordered = runner.segments.filter { $0.audioID == segment.audioID }.sorted {
            $0.start < $1.start
        }
        guard let index = ordered.firstIndex(where: { $0.id == segment.id }) else {
            return Layer1ReviewContext(before: [], after: [])
        }
        let before = ordered[..<index].flatMap(contextWords).suffix(5)
        let after = ordered.dropFirst(index + 1).flatMap(contextWords).prefix(3)
        return Layer1ReviewContext(before: Array(before), after: Array(after))
    }

    private func reviewText(for segment: Layer1Segment) -> String {
        let edited = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return edited.isEmpty
            ? contextWords(segment).joined(separator: " ")
            : Layer1GroundTruthStore.normalizeForReview(text)
    }

    private func reviewText(for suggestion: Layer1ModelSuggestion) -> String {
        suggestion.reviewText ?? Layer1GroundTruthStore.normalizeForReview(suggestion.text ?? "")
    }

    private func contextWords(_ segment: Layer1Segment) -> [String] {
        if segment.decision.status == .verified {
            return Layer1GroundTruthStore.normalizeForReview(segment.decision.text ?? "")
                .split(whereSeparator: \.isWhitespace).map(String.init)
        }
        for modelID in segment.proposalOrder {
            guard let suggestion = segment.modelSuggestions[modelID],
                suggestion.status == .completed,
                !reviewText(for: suggestion).isEmpty
            else { continue }
            return reviewText(for: suggestion).split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return []
    }

    private func loadCurrent() {
        guard let segment = current else { return }
        guard loadedSegmentID != segment.id else { return }
        loadedSegmentID = segment.id
        text = Layer1GroundTruthStore.normalizeForReview(segment.decision.text ?? "")
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
        let original: String?
        if let sourceModelID, let suggestion = segment.modelSuggestions[sourceModelID] {
            original = reviewText(for: suggestion)
        } else {
            original = nil
        }
        let reviewText = Layer1GroundTruthStore.normalizeForReview(text)
        let action: Layer1HumanAction =
            sourceModelID == nil ? .manual : (original == reviewText ? .selectedModel : .selectedAndEdited)
        save(segment, text: reviewText, action: action)
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
        let padding = context ? 5.0 : 0
        let start = max(0, segment.start - padding)
        let end = min(duration, segment.end + padding)
        asr.stopPlayback()
        asr.togglePlayback(URL(fileURLWithPath: path), from: start, to: end)
    }
}

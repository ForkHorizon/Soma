import SwiftUI

/// The files a human still has to settle: play the original, read what each
/// engine heard, then either confirm a term pair or pick the correct variant.
///
/// Nothing is decided from text alone here. A term only enters the glossary
/// after the listener has heard the recording it came from, which is the whole
/// difference between a confirmed pair and a guess about spelling.
struct GroundTruthReviewList: View {
    @ObservedObject var asr: ASRManager
    let items: [GroundTruthVerdict]
    let onGlossaryChanged: () -> Void

    @State private var expanded = true
    @State private var openFile: String?
    @State private var settled: Set<String> = []

    private var pending: [GroundTruthVerdict] {
        items.filter { !settled.contains($0.file) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 0) {
                if pending.isEmpty {
                    Text("Nothing waiting on a human right now.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }
                ForEach(pending.prefix(150)) { item in
                    row(item)
                    Divider()
                }
                if pending.count > 150 {
                    Text("…and \(pending.count - 150) more")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Needs review (\(pending.count)) — fewest differing words first")
        }
        .padding(14)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { settled = GroundTruthGold.settled() }
    }

    private func row(_ item: GroundTruthVerdict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { toggle(item) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Text(item.edits > 0 ? "\(item.edits)w" : "—")
                        .font(.caption).monospaced().frame(width: 34, alignment: .trailing)
                        .foregroundStyle(item.edits <= 2 ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.file).font(.caption).monospaced()
                        Text(item.reason).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: openFile == item.file ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                // Without this the row only responds where it has drawn pixels,
                // so clicking the empty middle of a line does nothing.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if openFile == item.file {
                GroundTruthReviewDetail(asr: asr, item: item,
                                        onGlossaryChanged: onGlossaryChanged,
                                        onSettled: { settled.insert(item.file) })
            }
        }
        .padding(.vertical, 6)
    }

    private func toggle(_ item: GroundTruthVerdict) {
        if openFile == item.file {
            openFile = nil
            asr.stopPlayback()
        } else {
            openFile = item.file
        }
    }
}

struct GroundTruthReviewDetail: View {
    @ObservedObject var asr: ASRManager
    let item: GroundTruthVerdict
    let onGlossaryChanged: () -> Void
    let onSettled: () -> Void

    @State private var confirmed: Set<String> = []

    private var audioURL: URL { asr.recordingsDir.appendingPathComponent(item.file) }
    private var isPlaying: Bool { asr.playingURL == audioURL }

    /// GigaAM first: it is the independent vote, so it is the one worth reading
    /// against the audio before Whisper's more fluent phrasing anchors you.
    private var ordered: [(String, String)] {
        let order = ["gigaam", "gigaam-ctc", "w-greedy", "fw-beam", "w-prompt",
                     "w-fallback", "w-sample", "w-offset"]
        return order.compactMap { name in
            item.candidates[name].map { (name, $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // One button per disputed cluster. A single range could not work:
            // the disagreements scatter, so it either began after the first
            // disputed word or swallowed the whole recording.
            FlowingSpots(spots: item.spots, isPlaying: isPlaying,
                         play: { spot in
                             // Stop first: togglePlayback would read a second
                             // click on the same recording as "stop", so jumping
                             // from spot 1 to spot 2 would fall silent instead.
                             asr.stopPlayback()
                             asr.togglePlayback(audioURL, from: spot.lowerBound, to: spot.upperBound)
                         },
                         playAll: { asr.togglePlayback(audioURL) })
                .disabled(!FileManager.default.fileExists(atPath: audioURL.path))

            Text("Coloured words are where this transcript disagrees with the others; the rest is common to all of them.")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(GroundTruthDiff.group(ordered), id: \.text) { group in
                candidate(names: group.names, text: group.text)
            }

            if !item.terms.isEmpty {
                Divider()
                Text("Same word, different spelling?")
                    .font(.caption).bold()
                Text("Confirm only what you actually hear. A confirmed pair stops counting as a disagreement everywhere, so a wrong one hides real errors.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(item.terms) { pair in
                    termRow(pair)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Computed once per recording, not per candidate: every transcript is
    /// marked against the same anchor, so the highlights line up across them.
    private var marked: [String: GroundTruthDiff.Marked] {
        // Anchored on the tier-one decode, the same text the clip timings come
        // from, so a coloured word and the audio that plays answer the same
        // question. They used to be computed against different candidates.
        GroundTruthDiff.mark(ordered, anchor: "w-greedy")
    }

    private func candidate(names: [String], text: String) -> some View {
        let lead = names[0]
        let independent = names.contains { $0.hasPrefix("gigaam") }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(names.joined(separator: " · ")).font(.caption2).monospaced()
                    .foregroundStyle(independent ? .blue : .secondary)
                if names.count > 1 {
                    Text("identical").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Use this as the reference") {
                    GroundTruthGold.write(file: item.file, text: text, source: names.joined(separator: "+"))
                    asr.stopPlayback()
                    onSettled()
                }
                .buttonStyle(.link).font(.caption2)
            }
            GroundTruthDiff.render(marked[lead] ?? .init(words: [], differing: []),
                                   tint: independent ? .blue : .orange)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func termRow(_ pair: TermPair) -> some View {
        let done = confirmed.contains(pair.id) || GroundTruthGlossary.contains(heard: pair.heard, written: pair.written)
        return HStack(spacing: 10) {
            Text("\(pair.heard)  →  \(pair.written)").font(.callout).monospaced()
            Spacer()
            if done {
                Label("In glossary", systemImage: "checkmark.circle.fill")
                    .font(.caption2).foregroundStyle(.green)
                Button("Undo") {
                    GroundTruthGlossary.forget(heard: pair.heard, written: pair.written)
                    confirmed.remove(pair.id)
                    onGlossaryChanged()
                }
                .buttonStyle(.link).font(.caption2)
            } else {
                Button("Same word") {
                    GroundTruthGlossary.confirm(heard: pair.heard, written: pair.written)
                    confirmed.insert(pair.id)
                    onGlossaryChanged()
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}


/// The disputed clips plus the whole recording, wrapped so a recording with
/// eight scattered disagreements does not push its transcripts off screen.
private struct FlowingSpots: View {
    let spots: [ClosedRange<Double>]
    let isPlaying: Bool
    let play: (ClosedRange<Double>) -> Void
    let playAll: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            ForEach(Array(spots.enumerated()), id: \.offset) { index, spot in
                Button {
                    play(spot)
                } label: {
                    Text(String(format: "%d · %.1fs", index + 1, spot.lowerBound))
                        .font(.caption2).monospacedDigit()
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
            if spots.isEmpty {
                Button(isPlaying ? "Stop" : "Play the original") { playAll() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Button(isPlaying ? "Stop" : "Whole recording") { playAll() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}

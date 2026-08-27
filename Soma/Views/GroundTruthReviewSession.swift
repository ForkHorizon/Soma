import SwiftUI

/// One decision at a time, keyboard-first, autoplay on open.
///
/// The old expanding-list panel made every file a wall of text and rewarded
/// long sittings. This one is built for the real workflow — five short visits
/// a day: one disputed word on screen, the clip already playing, 1–5 to pick
/// a reading, E to type what was actually said. When a file's last dispute is
/// settled, its assembled transcript gets one final edit before it becomes
/// gold, so a file can be finished even when every engine was wrong.
struct GroundTruthReviewSessionView: View {
    @ObservedObject var asr: ASRManager
    let items: [GroundTruthReviewItem]
    let onGlossaryChanged: () -> Void
    let onFinish: () -> Void

    @AppStorage("reviewAutoplay") private var autoplay = true
    @AppStorage("reviewSessionMinutes") private var sessionMinutes = 5.0

    @State private var choicesByFile: [String: [String: GroundTruthOperationChoice]] = [:]
    @State private var settled: Set<String> = []
    @State private var cursor = 0
    @State private var decisions = 0
    @State private var filesDone = 0
    @State private var started: Date?
    @State private var timeUp = false
    @State private var editing: GroundTruthVerdict?
    @State private var editingText = ""
    @State private var correction = ""
    @FocusState private var typing: Bool
    private var current: GroundTruthReviewItem? {
        var index = cursor
        while index < items.count {
            let item = items[index]
            if !settled.contains(item.verdict.file), choicesByFile[item.verdict.file]?[item.operation.id] == nil {
                return item
            }
            index += 1
        }
        return nil
    }

    private var pendingCount: Int {
        items.filter {
            !settled.contains($0.verdict.file)
                && choicesByFile[$0.verdict.file]?[$0.operation.id] == nil
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if editing != nil {
                finalEditor
            } else if current == nil || timeUp {
                summary
            } else if let item = current {
                decision(item)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 420, alignment: .topLeading)
        .onAppear(perform: begin)
        .onDisappear { asr.stopPlayback() }
    }

    // MARK: One disputed spot

    private func decision(_ item: GroundTruthReviewItem) -> some View {
        return VStack(alignment: .leading, spacing: 14) {
            header(item)
            context(item)
            ForEach(Array(item.operation.alternatives.enumerated()), id: \.element.id) { position, option in
                Button {
                    decide(item, option.text, option.names.joined(separator: "+"))
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text(String(position + 1)).font(.callout).monospacedDigit().bold()
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.accentColor.opacity(0.15)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.names.joined(separator: " · ")).font(.caption2).monospaced()
                                .foregroundStyle(.secondary)
                            Text(option.text.isEmpty ? "(nothing was said here)" : option.text)
                                .font(.body).multilineTextAlignment(.leading)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                TextField("None of these — type what you heard (E)", text: $correction)
                    .textFieldStyle(.roundedBorder)
                    .focused($typing)
                    .onSubmit { submitCorrection(item) }
                Button("Use (⏎)") { submitCorrection(item) }
                    .disabled(correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(termPairs(item)) { pair in
                Button("Always write “\(pair.written)” where an engine hears “\(pair.heard)”") {
                    GroundTruthGlossary.confirm(heard: pair.heard, written: pair.written)
                    decide(item, pair.written, "glossary")
                    onGlossaryChanged()
                }
                .buttonStyle(.link).font(.caption)
            }
            controls(item)
        }
        .id(item.id)
        .focusable(true)
        .onKeyPress(keys: .init(["1", "2", "3", "4", "5", "6", "7", "8", "9"])) { press in
            guard !typing, let position = Int(press.characters), position <= item.operation.alternatives.count else {
                return .ignored
            }
            let option = item.operation.alternatives[position - 1]
            decide(item, option.text, option.names.joined(separator: "+"))
            return .handled
        }
        .onKeyPress(.space) {
            guard !typing else { return .ignored }
            replay(item)
            return .handled
        }
        .onKeyPress(.escape) {
            cursor += 1
            return .handled
        }
    }

    private func header(_ item: GroundTruthReviewItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.verdict.file) · word \(item.index) of \(item.total)")
                    .font(.caption).monospaced().foregroundStyle(.secondary)
                Text(
                    "\(decisions) decided · \(filesDone) file(s) finished · ~\(max(1, Int(Double(pendingCount) * 5 / 60))) min left in queue"
                )
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("End session") { finish() }
        }
    }

    private func context(_ item: GroundTruthReviewItem) -> some View {
        let span = primarySpan(item)
        return Text("\(item.operation.contextBefore) \(span.isEmpty ? "…" : "[\(span)]") \(item.operation.contextAfter)")
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .textSelection(.enabled)
    }

    private func controls(_ item: GroundTruthReviewItem) -> some View {
        HStack {
            Button {
                replay(item)
            } label: {
                Label("Replay (Space)", systemImage: "play.fill")
            }
            .buttonStyle(.bordered).controlSize(.small)
            Button {
                asr.togglePlayback(asr.recordingsDir.appendingPathComponent(item.verdict.file))
            } label: {
                Label("Whole file", systemImage: "waveform")
            }
            .buttonStyle(.bordered).controlSize(.small)
            Toggle("Autoplay", isOn: $autoplay).controlSize(.mini)
            Spacer()
            Button("Skip (Esc)") { cursor += 1 }.controlSize(.small)
        }
    }

    // MARK: Final edit before gold

    /// The last look at a whole file. Here the reviewer can fix words no
    /// engine disputed — a mistake every engine copied never reaches the
    /// choice-by-choice flow, but it still lands in the reference.
    private var finalEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(editing?.file ?? "") — last check").font(.callout).monospaced()
            Text(
                "Gold is exactly what was said, including hesitation sounds (а, э, мм) and repeated words when they were really spoken. Fix anything the engines all got wrong — punctuation and capitalisation do not matter, WER ignores them."
            )
            .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $editingText)
                .font(.body).frame(minHeight: 160)
                .padding(6).background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Back") { editing = nil }
                Spacer()
                Button("Add to gold (⌘⏎)") { commitGold() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    // MARK: Session bookkeeping

    private func begin() {
        settled = GroundTruthGold.settled()
        // Carry over decisions already on disk: a file half-finished in an
        // earlier session must not re-ask what was answered there. A row whose
        // signature no longer matches the operation (a re-vote changed the
        // question) is dropped by choices(for:) itself.
        for verdict in Set(items.map(\.verdict)) {
            choicesByFile[verdict.file] = GroundTruthReviewProgress.choices(for: verdict)
        }
        started = started ?? Date()
        // A file whose decisions all landed in an earlier sitting but whose
        // gold row never did (the app closed at the final editor) reopens at
        // that edit, not at a summary that claims the queue is clear.
        offerAnyFinalEdit()
        if let item = current { autoplayClip(item) }
    }

    /// First file in the queue that is fully decided but not yet in gold.
    private func offerAnyFinalEdit() {
        guard editing == nil else { return }
        for verdict in Set(items.map(\.verdict)) where !settled.contains(verdict.file) {
            offerFinalEdit(verdict)
            if editing != nil { return }
        }
    }

    private func replay(_ item: GroundTruthReviewItem) { autoplayClip(item) }

    private func autoplayClip(_ item: GroundTruthReviewItem) {
        asr.stopPlayback()
        let url = asr.recordingsDir.appendingPathComponent(item.verdict.file)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if let seconds = item.operation.seconds {
            asr.togglePlayback(url, from: seconds.lowerBound, to: seconds.upperBound)
        } else {
            asr.togglePlayback(url)
        }
    }

    private func submitCorrection(_ item: GroundTruthReviewItem) {
        let text = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        decide(item, text, "manual")
    }

    private func decide(_ item: GroundTruthReviewItem, _ text: String, _ source: String) {
        asr.stopPlayback()
        GroundTruthReviewProgress.record(
            file: item.verdict.file, operation: item.operation,
            text: text, source: source)
        choicesByFile[item.verdict.file, default: [:]][item.operation.id] =
            GroundTruthOperationChoice(signature: item.operation.signature, text: text, source: source)
        decisions += 1
        correction = ""
        cursor = items.firstIndex(where: { $0.id == item.id }).map { $0 + 1 } ?? cursor + 1
        offerFinalEdit(item.verdict)
        checkTime()
    }

    /// All of a file's shown decisions made → one final edit, then gold.
    private func offerFinalEdit(_ verdict: GroundTruthVerdict) {
        guard editing == nil else { return }
        let needed = verdict.operations.filter { $0.alternatives.count > 1 }
        let done = choicesByFile[verdict.file] ?? [:]
        guard needed.allSatisfy({ done[$0.id] != nil }),
            let text = GroundTruthGold.assemble(verdict, choices: done)
        else { return }
        editing = verdict
        editingText = text
    }

    private func commitGold() {
        guard let verdict = editing else { return }
        GroundTruthGold.write(
            file: verdict.file,
            text: editingText.trimmingCharacters(in: .whitespacesAndNewlines),
            source: "review-session")
        settled.insert(verdict.file)
        filesDone += 1
        editing = nil
        offerAnyFinalEdit()
        checkTime()
        if current == nil, editing == nil { finish() }
    }

    private func checkTime() {
        guard let started else { return }
        if Date().timeIntervalSince(started) > sessionMinutes * 60 {
            timeUp = true
            asr.stopPlayback()
        }
    }

    private func finish() {
        asr.stopPlayback()
        onFinish()
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(timeUp ? "Time's up — nice sitting." : "Queue cleared for now.")
                .font(.title3).bold()
            Text(
                "\(decisions) decision(s) · \(filesDone) file(s) added to gold · \(pendingCount) left in queue (~\(max(1, Int(Double(pendingCount) * 5 / 60))) min)."
            )
            .font(.callout).foregroundStyle(.secondary)
            Text("Everything is already saved — closing now loses nothing; the next session picks up here.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if timeUp, current != nil {
                    Button("Keep going") { timeUp = false }
                }
                Spacer()
                Button("Done") { finish() }.buttonStyle(.borderedProminent)
            }
        }
    }

    /// The primary transcript's own words over the anchor — shown as the red
    /// spot so the reviewer reads what the alternatives would replace.
    private func primarySpan(_ item: GroundTruthReviewItem) -> String {
        let words = (item.verdict.candidates["w-greedy"] ?? "").split(separator: " ").map(String.init)
        guard item.operation.anchor.lowerBound >= 0, item.operation.anchor.upperBound <= words.count else { return "" }
        return words[item.operation.anchor].joined(separator: " ")
    }

    /// Single-word cross-script pairs from this spot, offered as a decision
    /// that outlives the recording. Confirmed pairs stop counting as
    /// disagreements everywhere — only click when it is the same word.
    private func termPairs(_ item: GroundTruthReviewItem) -> [TermPair] {
        let words = item.operation.alternatives
            .map { GroundTruthGlossary.normalize($0.text) }
            .filter { !$0.isEmpty && !$0.contains(" ") }
        let latin = words.filter { $0.contains { $0.isASCII && $0.isLetter } }
        return Set(latin).sorted().flatMap { written in
            Set(words).subtracting(latin).sorted()
                .filter { !GroundTruthGlossary.contains(heard: $0, written: written) }
                .map { TermPair(heard: $0, written: written) }
        }
    }
}

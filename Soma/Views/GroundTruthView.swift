import AppKit
import SwiftUI

struct GroundTruthView: View {
    @ObservedObject var asr: ASRManager
    @ObservedObject var runner: Layer1GroundTruthRunner
    @State private var analysisPresented = false
    @State private var reviewPresented = false
    @State private var historyPresented = false
    @State private var qualityPresented = false

    var body: some View {
        SomaPage(maxWidth: 1080) {
            WorkflowHeader(
                title: "Ground Truth",
                subtitle:
                    "Build a word-for-word reference set. Every final segment is confirmed by a person, never by model agreement alone.",
                icon: "waveform.badge.mic",
                tone: layer1Tone,
                trailing: AnyView(corpusSummary)
            )

            SomaPanel(
                title: "Layer 1 · Verbatim recognition",
                subtitle: "Run local ASR heads on the original audio, then settle every segment by ear.",
                icon: "text.word.spacing",
                tone: layer1Tone
            ) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 12)], spacing: 12) {
                    actionCard(
                        title: "Finished",
                        value: "\(finishedFiles.formatted()) / \(asr.recordingsTotal.formatted())",
                        detail: "\(finishedPercent)% of the whole corpus · open history",
                        icon: "checkmark.seal.fill",
                        tone: .good,
                        action: { historyPresented = true }
                    )
                    actionCard(
                        title: "AI analysis",
                        value: "\(analysedFiles.formatted()) / \(asr.recordingsTotal.formatted())",
                        detail: analysisDetail,
                        icon: runner.isRunning ? "waveform.path.ecg" : "cpu",
                        tone: runner.isRunning ? .info : .neutral,
                        action: { analysisPresented = true }
                    )
                    actionCard(
                        title: "Human review",
                        value: "\(readyFiles.formatted()) files",
                        detail: "\(runner.reviewSegments.count.formatted()) segments waiting for a decision",
                        icon: "person.crop.circle.badge.checkmark",
                        tone: readyFiles > 0 ? .warning : .neutral,
                        action: { reviewPresented = true }
                    )
                    actionCard(
                        title: "AI quality",
                        value: qualitySummary.matchLabel,
                        detail: qualitySummary.detail,
                        icon: "chart.bar.xaxis",
                        tone: qualitySummary.tone,
                        action: { qualityPresented = true }
                    )
                }
            }

            SomaPanel(
                title: "Layer 2",
                subtitle: "AI quality will appear here when this layer is configured.",
                icon: "square.2.layers.3d",
                tone: .neutral
            ) {
                Text("No work has been added to this layer yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $analysisPresented) {
            Layer1AnalysisSheet(asr: asr, runner: runner)
        }
        .sheet(isPresented: $reviewPresented) {
            Layer1ReviewView(asr: asr, runner: runner)
        }
        .sheet(isPresented: $historyPresented) {
            Layer1HistorySheet(runner: runner)
        }
        .sheet(isPresented: $qualityPresented) {
            Layer1QualitySheet(runner: runner)
        }
        .onAppear { asr.refreshRecordings() }
    }

    private var corpusSummary: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("\(asr.recordingsTotal.formatted()) files · \(asr.totalAudioDuration / 3600, specifier: "%.1f") h")
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
            Button("Open recordings folder") {
                NSWorkspace.shared.activateFileViewerSelecting([asr.recordingsDir])
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var layer1Tone: SomaStatusTone {
        if runner.isRunning { return .info }
        if readyFiles > 0 { return .warning }
        return finishedFiles > 0 ? .good : .neutral
    }

    private var finishedFiles: Int { runner.store.fullyVerifiedFilesCount() }
    private var analysedFiles: Int { runner.store.completeFilesCount() }
    private var readyFiles: Int { runner.store.readyFilesCount() }
    private var remainingAudio: Int { max(0, asr.recordingsTotal - runner.files.count) }
    private var finishedPercent: Int {
        guard asr.recordingsTotal > 0 else { return 0 }
        return Int((Double(finishedFiles) / Double(asr.recordingsTotal) * 100).rounded())
    }

    private var analysisDetail: String {
        if runner.isRunning, let fileID = runner.currentFileID,
            let file = runner.store.file(for: fileID)
        {
            return "Running \(file.url.lastPathComponent)"
        }
        if runner.pendingRuns > 0 { return "\(runner.pendingRuns.formatted()) model runs queued" }
        return "\(remainingAudio.formatted()) recordings not added yet"
    }

    private func actionCard(
        title: String, value: String, detail: String, icon: String,
        tone: SomaStatusTone, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: icon).foregroundStyle(tone.color)
                    Text(title).font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.tertiary)
                }
                Text(value)
                    .font(.system(.title3, design: .monospaced).bold())
                    .foregroundStyle(tone.color)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .background(SomaDesign.elevatedBackground)
            .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
            .overlay(RoundedRectangle(cornerRadius: SomaDesign.radius).stroke(tone.color.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(value). \(detail)")
    }

    private var qualitySummary: Layer1ModelQuality {
        layer1Quality(models: runner.models, segments: runner.segments).values.reduce(into: .init()) { total, quality in
            total.exact += quality.exact
            total.evaluated += quality.evaluated
            total.accepted += quality.accepted
            total.edited += quality.edited
            total.failed += quality.failed
        }
    }
}

struct Layer1ModelQuality {
    var exact = 0
    var evaluated = 0
    var accepted = 0
    var edited = 0
    var failed = 0

    var matchLabel: String {
        guard evaluated > 0 else { return "No verified text" }
        return "\(Int((Double(exact) / Double(evaluated) * 100).rounded()))% quality"
    }

    var detail: String {
        guard evaluated > 0 else { return "Open details after human review" }
        return "\(exact)/\(evaluated) exact · open details"
    }

    var tone: SomaStatusTone {
        guard evaluated > 0 else { return .neutral }
        let rate = Double(exact) / Double(evaluated)
        if rate >= 0.9 { return .good }
        if rate >= 0.7 { return .info }
        return .warning
    }
}

func layer1Quality(models: [Layer1ModelSpec], segments: [Layer1Segment]) -> [String: Layer1ModelQuality] {
    var result = Dictionary(uniqueKeysWithValues: models.map { ($0.id, Layer1ModelQuality()) })
    for segment in segments {
        for model in models {
            guard let suggestion = segment.modelSuggestions[model.id] else { continue }
            var quality = result[model.id] ?? .init()
            if suggestion.status == .failed { quality.failed += 1 }
            if segment.decision.status == .verified,
                let reference = segment.decision.normalizedText,
                !reference.isEmpty,
                suggestion.status == .completed
            {
                quality.evaluated += 1
                if Layer1GroundTruthStore.normalize(suggestion.text ?? "") == reference { quality.exact += 1 }
                if segment.decision.sourceModelID == model.id {
                    if segment.decision.action == .selectedModel { quality.accepted += 1 }
                    if segment.decision.action == .selectedAndEdited { quality.edited += 1 }
                }
            }
            result[model.id] = quality
        }
    }
    return result
}

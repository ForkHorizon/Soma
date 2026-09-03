import AppKit
import SwiftUI

struct Layer1AnalysisSheet: View {
    let asr: ASRManager
    @ObservedObject var runner: Layer1GroundTruthRunner
    @Environment(\.dismiss) private var dismiss
    @State private var batchCount = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Layer 1 · AI analysis").font(.title3.bold())
                    Text("Add only new recordings, then run every configured ASR head on the original audio.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            HStack(spacing: 10) {
                MetricTile(
                    title: "Not added", value: max(0, asr.recordingsTotal - runner.files.count).formatted(), detail: "recordings",
                    tone: .neutral)
                MetricTile(
                    title: "Queued", value: runner.pendingRuns.formatted(), detail: queuedDetail,
                    tone: runner.pendingRuns > 0 ? .info : .neutral)
                MetricTile(
                    title: "Ready", value: runner.store.readyFilesCount().formatted(), detail: "files for human review", tone: .warning)
            }

            HStack(spacing: 10) {
                Stepper("\(batchCount) new recordings", value: $batchCount, in: 1...500)
                Button("Add to analysis") { runner.addBatch(count: batchCount, asr: asr) }
                    .buttonStyle(.borderedProminent)
                Button(runner.isRunning ? "Stop queue" : "Run queue") {
                    runner.isRunning ? runner.stop() : runner.start()
                }
                .buttonStyle(.bordered)
                Button("Retry failed") { runner.retryFailed() }
                    .disabled(runner.isRunning || !hasFailures)
            }

            if let failure = runner.failure {
                StatusBanner(title: "Queue needs attention", detail: failure, tone: .danger)
            }
            if let fileID = runner.currentFileID, let file = runner.store.file(for: fileID) {
                StatusBanner(
                    title: "Processing \(file.url.lastPathComponent)",
                    detail: runner.models.first(where: { $0.id == runner.currentModelID })?.title ?? "ASR model",
                    tone: .info,
                    isLoading: true
                )
            }

            Divider()
            DisclosureGroup("All model heads") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(runner.models) { model in
                        HStack {
                            Text(model.title).font(.callout)
                            Spacer()
                            Text(model.family).font(.caption).foregroundStyle(.secondary)
                            if model.optional { StatusChip(text: "Optional", tone: .neutral) }
                        }
                    }
                    HStack {
                        Text("Commands are local to this Mac.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open configuration") {
                            NSWorkspace.shared.activateFileViewerSelecting([runner.store.commandConfigurationURL])
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(22)
        .frame(width: 720, alignment: .topLeading)
    }

    private var queuedDetail: String {
        let queued = runner.store.queuedRuns()
        let audioCount = Set(queued.map(\.audioID)).count
        let modelCount = Set(queued.map(\.modelID)).count
        guard runner.pendingRuns > 0 else { return "No model runs waiting" }
        if audioCount * modelCount == runner.pendingRuns {
            return "\(audioCount) audio files × \(modelCount) models = \(runner.pendingRuns) model runs"
        }
        return "\(runner.pendingRuns) model runs · \(audioCount) audio files · \(modelCount) models"
    }

    private var hasFailures: Bool {
        runner.files.contains { file in
            let status = runner.store.status(for: file.id)
            return status == .partial || status == .failed
        }
    }
}

struct Layer1HistorySheet: View {
    @ObservedObject var runner: Layer1GroundTruthRunner
    @Environment(\.dismiss) private var dismiss
    @State private var expandedFileID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Layer 1 history").font(.title3.bold())
                    Text("Every model answer and every saved human decision remain available here.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            if runner.files.isEmpty {
                ContentUnavailableView(
                    "No analysis yet", systemImage: "tray", description: Text("Add recordings to the Layer 1 queue first."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(runner.files) { file in
                            fileHistory(file)
                        }
                    }
                }
                .frame(maxHeight: 520)
            }
        }
        .padding(22)
        .frame(width: 820, alignment: .topLeading)
    }

    private func fileHistory(_ file: Layer1AudioFile) -> some View {
        let open = expandedFileID == file.id
        let status = runner.store.status(for: file.id)
        let segments = runner.segments.filter { $0.audioID == file.id }.sorted { $0.start < $1.start }

        return VStack(alignment: .leading, spacing: 10) {
            fileHeader(file, status: status, segments: segments, isOpen: open)

            if open {
                Divider()
                Text("Human decisions").font(.caption.bold())
                if segments.isEmpty {
                    Text("Segments appear after every model head reaches a terminal state.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(segments) { segment in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(segment.start, specifier: "%.1f")–\(segment.end, specifier: "%.1f")")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 78, alignment: .leading)
                            Text(segment.decision.text?.isEmpty == false ? segment.decision.text! : "Pending human decision")
                                .font(.caption)
                                .foregroundStyle(segment.decision.status == .verified ? .primary : .secondary)
                            Spacer()
                            StatusChip(
                                text: segment.decision.action?.rawValue ?? "Pending",
                                tone: segment.decision.status == .verified ? .good : .warning)
                        }
                    }
                }

                modelAnswers(for: file)
            }
        }
        .padding(12)
        .background(SomaDesign.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
        .overlay(RoundedRectangle(cornerRadius: SomaDesign.radius).stroke(Color.secondary.opacity(0.12)))
    }

    private func fileHeader(
        _ file: Layer1AudioFile, status: Layer1BatchStatus, segments: [Layer1Segment], isOpen: Bool
    ) -> some View {
        Button {
            expandedFileID = isOpen ? nil : file.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.url.lastPathComponent).font(.callout.monospaced())
                    Text("\(String(format: "%.1f", file.duration)) s · \(segments.count) segments")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusChip(text: status.rawValue.capitalized, tone: tone(for: status))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modelAnswer(_ run: Layer1ModelRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(run.model).font(.caption.bold())
                Spacer()
                StatusChip(text: run.status.rawValue.capitalized, tone: runTone(run.status))
                Text(run.version).font(.caption2).foregroundStyle(.secondary)
            }
            Text(answerText(for: run))
                .font(.caption)
                .foregroundStyle(run.status == .failed ? .red : .primary)
                .textSelection(.enabled)
            if let raw = run.rawResponse, !raw.isEmpty {
                DisclosureGroup("Raw response") {
                    Text(raw).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func modelAnswers(for file: Layer1AudioFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model answers").font(.caption.bold()).padding(.top, 4)
            ForEach(runner.models) { model in
                if let run = runner.store.currentRun(audioID: file.id, modelID: model.id) {
                    modelAnswer(run)
                }
            }
        }
    }

    private func answerText(for run: Layer1ModelRun) -> String {
        if run.status == .failed { return run.error ?? "Model failed without an error message" }
        return run.text?.isEmpty == false ? run.text! : "No speech returned"
    }

    private func runTone(_ status: Layer1ModelRunStatus) -> SomaStatusTone {
        switch status {
        case .completed: return .good
        case .failed: return .danger
        case .running: return .info
        case .queued: return .neutral
        }
    }

    private func tone(for status: Layer1BatchStatus) -> SomaStatusTone {
        switch status {
        case .completed: return .good
        case .partial: return .warning
        case .failed: return .danger
        case .running: return .info
        case .queued: return .neutral
        }
    }
}

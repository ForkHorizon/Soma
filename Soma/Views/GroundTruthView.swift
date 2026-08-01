import SwiftUI

/// Panel for the overnight ground-truth build: start it, watch it, and see what
/// is left to adjudicate by hand.
struct GroundTruthView: View {
    @ObservedObject var asr: ASRManager
    @StateObject private var runner = GroundTruthRunner()
    @AppStorage("groundTruthBestOf") private var bestOf = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                controls
                progressCard
                counters
                GroundTruthMethodCard(bestOf: bestOf)
                GroundTruthReviewList(items: runner.reviewQueue)
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .onAppear { runner.loadExistingVerdicts() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ground Truth").font(.title2).bold()
            Text("Builds a reference transcript for every saved recording by making two different ASR architectures agree. Runs for hours; safe to leave overnight.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if runner.isRunning {
                    Button(role: .destructive) { runner.stop() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                } else {
                    Button { runner.start(asr: asr, bestOf: bestOf) } label: {
                        Label("Start run", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    // Both would hold a Whisper model at once, and this machine
                    // does not have the memory to spare for that.
                    .disabled(asr.isRecording || asr.isTranscribing)
                }
                Stepper(value: $bestOf, in: 1...25) {
                    Text("Sampled decodes per window: **\(bestOf)**")
                }
                .disabled(runner.isRunning)
                .frame(maxWidth: 320)
            }
            if asr.isRecording || asr.isTranscribing {
                Text("Finish the current transcription first — the run loads its own copy of the model.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let failure = runner.failure {
                Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(runner.stage).font(.callout)
                Spacer()
                Text("\(runner.decided) of \(runner.files) decided")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: runner.progress)
            HStack {
                Text(runner.currentFile.isEmpty ? " " : runner.currentFile)
                    .font(.caption).monospaced().foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("\(runner.remaining) left").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var counters: some View {
        HStack(spacing: 12) {
            counter("Accepted", runner.accepted, "checkmark.seal", .green)
            counter("Needs review", runner.review, "person.fill.questionmark", .orange)
            counter("Errors", runner.errors, "exclamationmark.triangle", .red)
            counter("No speech", runner.empty, "speaker.slash", .secondary)
        }
    }

    private func counter(_ title: String, _ value: Int, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text("\(value)").font(.title).monospacedDigit().foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

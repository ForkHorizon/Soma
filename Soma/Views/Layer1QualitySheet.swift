import SwiftUI

struct Layer1QualitySheet: View {
    @ObservedObject var runner: Layer1GroundTruthRunner
    @Environment(\.dismiss) private var dismiss

    private var quality: [String: Layer1ModelQuality] {
        layer1Quality(models: runner.models, segments: runner.segments, runs: runner.state.modelRuns)
    }

    private var summary: Layer1ModelQuality {
        quality.values.reduce(into: .init()) { total, value in
            total.exact += value.exact
            total.evaluated += value.evaluated
            total.accepted += value.accepted
            total.edited += value.edited
            total.failed += value.failed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Layer 1 · AI quality").font(.title3.bold())
                    Text("Exact matches are measured against text confirmed by a person.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            MetricTile(
                title: "Overall quality", value: summary.matchLabel, detail: "\(summary.exact)/\(summary.evaluated) exact matches",
                tone: summary.tone)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 12)], spacing: 10) {
                ForEach(runner.models) { model in
                    modelRow(model, quality: quality[model.id] ?? .init())
                }
            }
        }
        .padding(22)
        .frame(width: 760, alignment: .topLeading)
    }

    private func modelRow(_ model: Layer1ModelSpec, quality: Layer1ModelQuality) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(model.title).font(.caption.bold()).lineLimit(1)
                Spacer()
                Text(quality.matchLabel).font(.caption2.monospacedDigit()).foregroundStyle(quality.tone.color)
            }
            Text("\(quality.exact)/\(quality.evaluated) exact · \(quality.accepted) accepted · \(quality.edited) edited")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            if quality.failed > 0 {
                Text("\(quality.failed) failed").font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

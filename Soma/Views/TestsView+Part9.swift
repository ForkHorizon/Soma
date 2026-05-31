import SwiftUI
import AppKit
import Foundation

extension TestsView {
    var modelStatsHeaderText: String {
        if let modelStats {
            let generated = shortDateTime(modelStats.generatedAt)
            return "\(modelStatsStatusText) · Generated \(generated) · Logs: \(stressDirectoryURL.path)"
        }
        return "\(modelStatsStatusText) · Logs: \(stressDirectoryURL.path)"
    }


    var selectedTranslationStats: TestModelRoleStats? {
        guard let modelStats else { return nil }
        if let selectedTranslationStatsID,
           let selected = modelStats.translationModels.first(where: { $0.id == selectedTranslationStatsID }) {
            return selected
        }
        return modelStats.translationModels.first
    }


    var selectedImproverStats: TestModelRoleStats? {
        guard let modelStats else { return nil }
        if let selectedImproverStatsID,
           let selected = modelStats.improverModels.first(where: { $0.id == selectedImproverStatsID }) {
            return selected
        }
        return modelStats.improverModels.first
    }


    func modelStatsSection(
        title: String,
        subtitle: String,
        rows: [TestModelRoleStats],
        selectedID: Binding<String?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                StatusChip(text: "\(rows.count) models", tone: rows.isEmpty ? .neutral : .info)
                Spacer()
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if rows.isEmpty {
                Text("No rows yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.38))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 0) {
                    modelStatsHeaderRow
                    Divider()
                    ForEach(rows) { row in
                        modelStatsRow(row, selectedID: selectedID)
                        Divider()
                    }
                }
                .background(Color(NSColor.textBackgroundColor).opacity(0.40))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
            }
        }
    }


    var modelStatsHeaderRow: some View {
        HStack(spacing: 10) {
            Text("Model").frame(maxWidth: .infinity, alignment: .leading)
            Text("Runs").frame(width: 58, alignment: .trailing)
            Text("Avg").frame(width: 50, alignment: .trailing)
            Text("Med").frame(width: 50, alignment: .trailing)
            Text("Min").frame(width: 50, alignment: .trailing)
            Text("Low").frame(width: 46, alignment: .trailing)
            Text("Conf fail").frame(width: 68, alignment: .trailing)
            Text("Pipe fail").frame(width: 68, alignment: .trailing)
            Text("Deg").frame(width: 42, alignment: .trailing)
            Text("Runtime").frame(width: 64, alignment: .trailing)
            Text("Last").frame(width: 136, alignment: .leading)
        }
        .font(.caption2.bold())
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }


    func modelStatsRow(_ row: TestModelRoleStats, selectedID: Binding<String?>) -> some View {
        Button {
            selectedID.wrappedValue = row.id
        } label: {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text(row.model)
                        .font(.caption.monospaced().weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    StatusChip(text: row.provider, tone: providerTone(row.provider))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(row.attempts)").frame(width: 58, alignment: .trailing)
                Text(formatConfidence(row.avgConfidence)).foregroundColor(confidenceTone(row.avgConfidence).color).frame(width: 50, alignment: .trailing)
                Text(formatConfidence(row.medianConfidence)).frame(width: 50, alignment: .trailing)
                Text(formatConfidence(row.minConfidence)).foregroundColor(confidenceTone(row.minConfidence).color).frame(width: 50, alignment: .trailing)
                Text("\(row.lowConfidenceCount)").foregroundColor(row.lowConfidenceCount > 0 ? .orange : .secondary).frame(width: 46, alignment: .trailing)
                Text("\(row.confidenceFailedCount)").foregroundColor(row.confidenceFailedCount > 0 ? .orange : .secondary).frame(width: 68, alignment: .trailing)
                Text("\(row.pipelineFailedCount)").foregroundColor(row.pipelineFailedCount > 0 ? .red : .secondary).frame(width: 68, alignment: .trailing)
                Text("\(row.degradedCount)").foregroundColor(row.degradedCount > 0 ? .orange : .secondary).frame(width: 42, alignment: .trailing)
                Text(formatOptionalSeconds(row.avgSeconds)).frame(width: 64, alignment: .trailing)
                Text(shortDateTime(row.lastTestedAt)).frame(width: 136, alignment: .leading)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selectedID.wrappedValue == row.id ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
        .help("attempts \(row.attempts), confidence count \(row.confidenceCount)")
    }


    func modelStatsDetailPanel(title: String, row: TestModelRoleStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(title): \(row.model)")
                    .font(.caption.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                StatusChip(text: row.provider, tone: providerTone(row.provider))
                Spacer()
                StatusChip(text: "\(row.attempts) attempts", tone: row.attempts > 0 ? .info : .neutral)
                StatusChip(text: "low \(row.lowConfidenceCount)", tone: row.lowConfidenceCount > 0 ? .warning : .good)
            }

            HStack(alignment: .top, spacing: 12) {
                modelStatsDetailColumn(
                    title: "Worst cases",
                    lines: row.worstCases.prefix(6).map { item in
                        let confidence = item.confidence.map { String(format: "%.2f", $0) } ?? (item.confidenceFailed == true ? "failed" : "n/a")
                        let related = item.relatedModel.map { " · \($0)" } ?? ""
                        return "\(item.caseID): \(confidence) · \(item.status ?? "unknown")\(related)"
                    }
                )
                modelStatsDetailColumn(
                    title: "Top warnings",
                    lines: row.topWarnings.prefix(6).map { "\($0.count)x \($0.warning)" }
                )
                modelStatsDetailColumn(
                    title: "Recent runs",
                    lines: row.recentRuns.prefix(6).map { run in
                        let name = URL(fileURLWithPath: run.runDir).lastPathComponent
                        return "\(shortDateTime(run.finishedAt)) · \(name) · \(run.attempts) · avg \(formatConfidence(run.avgConfidence))"
                    }
                )
            }
        }
        .padding(10)
        .background(Color(NSColor.textBackgroundColor).opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.10)))
    }


    func modelStatsDetailColumn(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.bold())
            Text(lines.isEmpty ? "-" : lines.joined(separator: "\n"))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(8)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }


    var modelResultsTable: some View {
        VStack(spacing: 0) {
            resultHeaderRow
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(resultRows) { row in
                        resultMatrixRow(row)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.40))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

}

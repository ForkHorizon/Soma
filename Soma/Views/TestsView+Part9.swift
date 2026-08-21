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
        if let selectedTranslationStatsID,
            let selected = sortedTranslationModelStats.first(where: { $0.id == selectedTranslationStatsID })
        {
            return selected
        }
        return sortedTranslationModelStats.first
    }

    var selectedImproverStats: TestModelRoleStats? {
        if let selectedImproverStatsID,
            let selected = sortedImproverModelStats.first(where: { $0.id == selectedImproverStatsID })
        {
            return selected
        }
        return sortedImproverModelStats.first
    }

    func modelStatsSection(
        title: String,
        subtitle: String,
        rows: [TestModelRoleStats],
        selectedID: Binding<String?>,
        sort: Binding<TestModelStatsSort?>
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
                    modelStatsHeaderRow(sort: sort)
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

    func modelStatsHeaderRow(sort: Binding<TestModelStatsSort?>) -> some View {
        HStack(spacing: 10) {
            modelStatsHeaderButton("Model", column: .model, sort: sort, alignment: .leading)
            modelStatsHeaderButton(
                "Runs", column: .attempts, sort: sort, width: 54, alignment: .trailing, help: "Total attempts for this model.")
            modelStatsHeaderButton(
                "Score", column: .quality, sort: sort, width: 58, alignment: .trailing,
                help: "Main trust score across all attempts. Failed attempts count as 0.")
            modelStatsHeaderButton(
                "OK", column: .ok, sort: sort, width: 64, alignment: .trailing, help: "Usable scored attempts out of total attempts.")
            modelStatsHeaderButton(
                "Problems", column: .problems, sort: sort, width: 72, alignment: .trailing,
                help: "Attempts with any judge failure, run failure, or degraded warning. Each attempt counts once.")
            modelStatsHeaderButton(
                "Clean", column: .clean, sort: sort, width: 56, alignment: .trailing,
                help: "Share of attempts without judge failure, run failure, or degraded warning.")
            modelStatsHeaderButton(
                "Speed", column: .runtime, sort: sort, width: 60, alignment: .trailing, help: "Average model runtime for this role.")
            modelStatsHeaderButton("Last", column: .last, sort: sort, width: 136, alignment: .leading)
        }
        .font(.caption2.bold())
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    func modelStatsHeaderButton(
        _ title: String,
        column: TestModelStatsSortColumn,
        sort: Binding<TestModelStatsSort?>,
        width: CGFloat? = nil,
        alignment: Alignment,
        help: String? = nil
    ) -> some View {
        let active = sort.wrappedValue?.column == column
        Button {
            toggleModelStatsSort(column, sort: sort)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .lineLimit(1)
                Image(systemName: sort.wrappedValue?.ascending == true ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(active ? 1 : 0)
            }
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
            .frame(width: width, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help.map { "\($0) Sort by \(title)." } ?? "Sort by \(title)")
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

                Text("\(row.attempts)").frame(width: 54, alignment: .trailing)
                Text(formatConfidence(row.qualityScore))
                    .foregroundColor(confidenceTone(row.qualityScore).color)
                    .frame(width: 58, alignment: .trailing)
                Text("\(row.confidenceCount)/\(row.attempts)")
                    .foregroundColor(row.confidenceCount == row.attempts ? .secondary : .orange)
                    .frame(width: 64, alignment: .trailing)
                Text("\(modelStatsProblemCount(row))")
                    .foregroundColor(modelStatsProblemCount(row) > 0 ? .orange : .secondary)
                    .frame(width: 72, alignment: .trailing)
                Text(modelStatsCleanLabel(row))
                    .foregroundColor(confidenceTone(modelStatsCleanRate(row)).color)
                    .frame(width: 56, alignment: .trailing)
                Text(formatOptionalSeconds(row.avgSeconds)).frame(width: 60, alignment: .trailing)
                Text(shortDateTime(row.lastTestedAt)).frame(width: 136, alignment: .leading)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selectedID.wrappedValue == row.id ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(
            "runs \(row.attempts), score \(formatConfidence(row.qualityScore)), OK \(row.confidenceCount)/\(row.attempts), problems \(modelStatsProblemCount(row)), clean \(modelStatsCleanLabel(row))"
        )
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
                StatusChip(text: "score \(formatConfidence(row.qualityScore))", tone: confidenceTone(row.qualityScore))
                StatusChip(text: "OK \(row.confidenceCount)/\(row.attempts)", tone: row.confidenceCount == row.attempts ? .good : .warning)
                StatusChip(text: "problems \(modelStatsProblemCount(row))", tone: modelStatsProblemCount(row) > 0 ? .warning : .good)
                StatusChip(text: "clean \(modelStatsCleanLabel(row))", tone: confidenceTone(modelStatsCleanRate(row)))
            }

            HStack(alignment: .top, spacing: 12) {
                modelStatsDetailColumn(
                    title: "Usable score stats",
                    lines: [
                        "Avg OK: \(formatConfidence(row.avgConfidence))",
                        "Median OK: \(formatConfidence(row.medianConfidence))",
                        "Min OK: \(formatConfidence(row.minConfidence))",
                        "Low <75: \(row.lowConfidenceCount)",
                    ]
                )
                modelStatsDetailColumn(
                    title: "Problem breakdown",
                    lines: [
                        "Any problem: \(modelStatsProblemCount(row))",
                        "Clean: \(modelStatsCleanLabel(row))",
                        "Worst effective: \(formatConfidence(modelStatsWorstEffectiveScore(row)))",
                        "Judge failed: \(row.confidenceFailedCount)",
                        "Run failed: \(row.pipelineFailedCount)",
                        "Degraded: \(row.degradedCount)",
                    ]
                )
                modelStatsDetailColumn(
                    title: "Recent runs",
                    lines: row.recentRuns.prefix(6).map { run in
                        let name = URL(fileURLWithPath: run.runDir).lastPathComponent
                        return
                            "\(shortDateTime(run.finishedAt)) · \(name) · \(run.attempts) runs · score \(formatConfidence(run.qualityScore)) · OK avg \(formatConfidence(run.avgConfidence))"
                    }
                )
            }

            HStack(alignment: .top, spacing: 12) {
                modelStatsDetailColumn(
                    title: "Worst cases",
                    lines: row.worstCases.prefix(6).map { item in
                        let score = item.effectiveScore ?? item.confidence
                        let confidence =
                            item.confidenceFailed == true ? "effective 0.00" : (score.map { String(format: "%.2f", $0) } ?? "n/a")
                        let related = item.relatedModel.map { " · \($0)" } ?? ""
                        let warning = item.warnings?.first.map { " · \($0)" } ?? ""
                        return "\(item.caseID): \(confidence) · \(item.status ?? "unknown")\(related)\(warning)"
                    }
                )
                modelStatsDetailColumn(
                    title: "Top warnings",
                    lines: row.topWarnings.prefix(6).map { "\($0.count)x \($0.warning)" }
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

import SwiftUI
import AppKit
import Foundation

extension TestsView {
    var caseResultsTable: some View {
        VStack(spacing: 0) {
            caseResultHeaderRow
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(resultCaseGroups, id: \.caseID) { group in
                        HStack {
                            Text(group.title)
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(group.rows.count) operations")
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.08))

                        ForEach(group.rows) { row in
                            caseRunRow(row)
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.40))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    var caseResultHeaderRow: some View {
        HStack(spacing: 10) {
            Text("Pipeline").frame(maxWidth: .infinity, alignment: .leading)
            Text("Translation conf").frame(width: 96, alignment: .leading)
            Text("Improve conf").frame(width: 96, alignment: .leading)
            Text("Overall conf").frame(width: 96, alignment: .leading)
            Text("Status").frame(width: 76, alignment: .leading)
            Text("Low").frame(width: 44, alignment: .leading)
            Text("Time").frame(width: 58, alignment: .trailing)
        }
        .font(.caption2.bold())
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    var resultHeaderRow: some View {
        HStack(spacing: 10) {
            Text("Model pair").frame(maxWidth: .infinity, alignment: .leading)
            Text("Quality").frame(width: 60, alignment: .leading)
            Text("Translation conf").frame(width: 96, alignment: .leading)
            Text("Improve conf").frame(width: 96, alignment: .leading)
            Text("Overall conf").frame(width: 96, alignment: .leading)
            Text("OK/D/F").frame(width: 76, alignment: .leading)
            Text("Low").frame(width: 44, alignment: .leading)
            Text("Time").frame(width: 58, alignment: .trailing)
        }
        .font(.caption2.bold())
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    func resultMatrixRow(_ row: TestModelCombinationSummary) -> some View {
        Button {
            selectedResultRowID = row.id
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Translator: \(row.translatorModel)")
                        .font(.caption.monospaced().weight(.semibold))
                        .lineLimit(1)
                    Text("Improver: \(row.analyzerModel)")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(formatConfidence(row.qualityScore))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundColor(confidenceTone(row.qualityScore, failed: row.failed).color)
                    .frame(width: 60, alignment: .leading)
                confidenceSummaryCell(row.translationConfidence)
                    .frame(width: 96, alignment: .leading)
                confidenceSummaryCell(row.improveConfidence)
                    .frame(width: 96, alignment: .leading)
                confidenceSummaryCell(row.overallConfidence)
                    .frame(width: 96, alignment: .leading)
                Text("\(row.ok)/\(row.degraded)/\(row.failed)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(row.failed > 0 ? .red : (row.degraded > 0 ? .orange : .green))
                    .frame(width: 76, alignment: .leading)
                Text("\(row.lowConfidenceCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(row.lowConfidenceCount > 0 ? .orange : .secondary)
                    .frame(width: 44, alignment: .leading)
                Text(formatSeconds(row.durationSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selectedResultRowID == row.id ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    func caseRunRow(_ row: TestRunResult) -> some View {
        Button {
            if selectedRunRowID == row.id {
                toggleRunDebug(row.id)
            } else {
                selectedRunRowID = row.id
                expandedRunDebugIDs.insert(row.id)
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Translate: \(row.translatorModel)")
                        .font(.caption.monospaced().weight(.semibold))
                        .lineLimit(1)
                    Text("Improve: \(row.analyzerModel)")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                runConfidenceCell(row.translationConfidence)
                    .frame(width: 96, alignment: .leading)
                runConfidenceCell(row.improveConfidence)
                    .frame(width: 96, alignment: .leading)
                runConfidenceCell(row.overallConfidence)
                    .frame(width: 96, alignment: .leading)
                Text(row.status)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(runStatusTone(row.status).color)
                    .frame(width: 76, alignment: .leading)
                Text("\(runLowStageCount(row))")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(runLowStageCount(row) > 0 ? .orange : .secondary)
                    .frame(width: 44, alignment: .leading)
                Text(formatSeconds(row.seconds))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selectedRunRowID == row.id ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    func confidenceSummaryCell(_ stats: TestConfidenceAggregate) -> some View {
        HStack(spacing: 4) {
            Text(formatConfidence(stats.avg))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundColor(confidenceTone(stats.avg, failed: stats.failed ?? 0).color)
            if (stats.failed ?? 0) > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.orange)
            }
        }
        .help("avg \(formatConfidence(stats.avg)), min \(formatConfidence(stats.min)), failed \(stats.failed ?? 0)")
    }

    func runConfidenceCell(_ confidence: TestRunConfidence?) -> some View {
        let failed = confidence?.isFailed == true
        let value = confidence?.usableConfidence
        return HStack(spacing: 4) {
            Text(failed ? "failed" : formatConfidence(value))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundColor(confidenceTone(value, failed: failed ? 1 : 0).color)
            if failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.orange)
            }
        }
        .help(runConfidenceHelp(confidence))
    }

}

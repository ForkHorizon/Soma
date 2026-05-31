import SwiftUI
import AppKit
import Foundation

extension TestsView {
    var pipelineCountersPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Counters")
                .font(.caption.bold())

            HStack(spacing: 12) {
                progressMetric("Operation", totalCasesToRun > 0 ? "\(currentRunIndex)/\(totalCasesToRun)" : "-")
                progressMetric("Rejected", "\(rejectedTranslationCount)")
                progressMetric("Skipped", "\(skippedImproverCount)")
            }

            HStack(spacing: 12) {
                progressMetric("Confidence batches", "\(confidenceBatchesFinished)/\(confidenceBatchesStarted)")
                progressMetric("Running", "\(max(confidenceBatchesStarted - confidenceBatchesFinished, 0))")
                progressMetric("Queued", "\(max(estimatedConfidenceRequestCount - confidenceBatchesStarted, 0))")
                progressMetric("Est. requests", "~\(estimatedConfidenceRequestCount)")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.10)))
    }


    var recentActivityPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Activity")
                    .font(.caption.bold())
                Spacer()
                if !rawProgressLines.isEmpty {
                    Text("\(rawProgressLines.count) raw lines")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            if progressLines.isEmpty {
                Text("Start tests to see live pipeline events.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(progressLines.suffix(6).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .textSelection(.enabled)
            }

            DisclosureGroup("Raw log") {
                Text(rawProgressLines.suffix(8).joined(separator: "\n"))
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(10)
        .background(Color(NSColor.textBackgroundColor).opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.10)))
    }


    var testResultsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tablecells")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("Results")
                    .font(.subheadline.bold())
                StatusChip(text: "\(resultRunRows.count) operations", tone: resultRunRows.isEmpty ? .neutral : .info)
                StatusChip(text: "\(resultRows.count) combinations", tone: resultRows.isEmpty ? .neutral : .info)
                Spacer()
                Text(resultsStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if resultRows.isEmpty && resultRunRows.isEmpty {
                Text("Run tests to see operations and model-combination confidence.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                HStack {
                    Picker("Result mode", selection: $selectedResultsMode) {
                        ForEach(TestResultsMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)

                    Text(selectedResultsMode == .byModel
                         ? "Each row is one translator/improver pair aggregated across all cases."
                         : "Each row is one source prompt -> translation -> improved prompt operation.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                }

                switch selectedResultsMode {
                case .byModel:
                    modelResultsTable
                    if let selected = selectedResultRow {
                        resultDetailPanel(selected)
                    }
                case .byCase:
                    caseResultsTable
                    if let selected = selectedRunRow {
                        runDetailPanel(selected)
                    }
                }
            }
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }


    var modelStatsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("Model Stats", systemImage: "chart.bar.xaxis")
                    .font(.title3.weight(.semibold))
                if let modelStats {
                    StatusChip(text: "\(modelStats.scannedRuns) runs", tone: modelStats.scannedRuns > 0 ? .info : .neutral)
                    StatusChip(text: "\(modelStats.skippedRuns) skipped", tone: modelStats.skippedRuns > 0 ? .warning : .neutral)
                }
                Spacer()
                if isLoadingModelStats {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    loadModelStats()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    openStressLogsFolder()
                } label: {
                    Label("Open Logs Folder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Close") {
                    showModelStats = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(modelStatsHeaderText)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            Divider()

            if let modelStats {
                if modelStats.translationModels.isEmpty && modelStats.improverModels.isEmpty {
                    Text("No model statistics yet. Run tests to populate .stress, then refresh this sheet.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            modelStatsSection(
                                title: "Translation Models",
                                subtitle: "Russian or mixed input -> English translation. Attempts are deduplicated across improvers.",
                                rows: modelStats.translationModels,
                                selectedID: $selectedTranslationStatsID
                            )
                            if let selected = selectedTranslationStats {
                                modelStatsDetailPanel(title: "Translation details", row: selected)
                            }

                            modelStatsSection(
                                title: "Improver Models",
                                subtitle: "English translation -> final polished prompt. Attempts are counted per actual improve operation.",
                                rows: modelStats.improverModels,
                                selectedID: $selectedImproverStatsID
                            )
                            if let selected = selectedImproverStats {
                                modelStatsDetailPanel(title: "Improver details", row: selected)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
            } else {
                Text(modelStatsStatusText)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(18)
        .background(SomaDesign.pageBackground)
    }

}

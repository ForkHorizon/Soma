import SwiftUI
import AppKit
import Foundation

extension TestsView {
    var benchmarkModePanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.3.group.bubble")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Benchmark mode")
                        .font(.subheadline.bold())
                    StatusChip(text: selectedBenchmarkMode.rawValue, tone: .info)
                }
                Text(selectedBenchmarkMode.shortDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Picker(
                    "Benchmark mode",
                    selection: Binding(
                        get: { selectedBenchmarkMode },
                        set: { mode in
                            selectedBenchmarkMode = mode
                            saveBenchmarkMode(mode)
                        }
                    )
                ) {
                    ForEach(TestBenchmarkMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)

                Text(benchmarkEstimateText)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    var testRunControls: some View {
        HStack(spacing: 10) {
            Button {
                isRunningTests ? stopTests() : startAllTests()
            } label: {
                Label(isRunningTests ? "Stop Tests" : "Start All Tests", systemImage: isRunningTests ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!isRunningTests && !canStartTests)

            Text(runReadinessText)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if let lastRunOutputURL {
                Button {
                    NSWorkspace.shared.open(lastRunOutputURL)
                } label: {
                    Label("Open Output", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    var testOutputTabs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Output", selection: $selectedOutputTab) {
                ForEach(TestOutputTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            switch selectedOutputTab {
            case .progress:
                testProgressPanel
            case .results:
                testResultsPanel
            }
        }
    }

    var testProgressPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: isRunningTests ? "point.3.connected.trianglepath.dotted" : "chart.line.uptrend.xyaxis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Pipeline")
                            .font(.subheadline.bold())
                        StatusChip(text: currentStage, tone: pipelineStatusTone)
                    }
                    Text(currentTestStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(runElapsedText)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                    Text(totalCasesToRun > 0 ? "\(completedCases)/\(totalCasesToRun) operations" : "No active run")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(progressPercentText)
                        .font(.caption.monospacedDigit().bold())
                    Spacer()
                    Text("\(completedCases) complete, \(max(totalCasesToRun - completedCases, 0)) remaining")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ProgressView(value: progressValue, total: Double(max(totalCasesToRun, 1)))
                    .progressViewStyle(.linear)
            }

            pipelineTimeline

            HStack(alignment: .top, spacing: 12) {
                activeWorkPanel
                pipelineCountersPanel
            }

            recentActivityPanel
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    var pipelineTimeline: some View {
        HStack(spacing: 8) {
            ForEach(TestPipelineStep.allCases.indices, id: \.self) { index in
                let step = TestPipelineStep.allCases[index]
                pipelineStepView(step)
                if index < TestPipelineStep.allCases.count - 1 {
                    Rectangle()
                        .fill(pipelineConnectorColor(before: step))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 4)
    }

    var activeWorkPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Active Work")
                    .font(.caption.bold())
                StatusChip(text: translationGateStateText, tone: translationGateTone)
                Spacer()
            }

            HStack(spacing: 12) {
                progressMetric("Case", currentCaseID)
                progressMetric("Translator", currentProgressEvent?.translatorModel ?? translatorFromPair)
                progressMetric("Improver / Batch", activeImproverOrBatchText)
                progressMetric("Confidence", activeConfidenceSummary)
            }

            if let reason = currentProgressEvent?.reason,
                !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.10)))
    }

}

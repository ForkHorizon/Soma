import SwiftUI
import AppKit
import Foundation

extension TestsView {
    func queueCandidatePanel(title: String, role: TestModelRole, selected: [String], update: @escaping ([String]) -> Void) -> some View {
        let statsByModel = modelStatsLookup(statsRows(for: role))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.bold())
                Spacer()
                StatusChip(text: "\(selected.count)", tone: selected.isEmpty ? .warning : .info)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(queueStageModelRows(selected: selected, statsByModel: statsByModel, role: role), id: \.model) { preset in
                        let isSelected = selected.contains { $0.caseInsensitiveCompare(preset.model) == .orderedSame }
                        let stats = statsByModel[preset.model.lowercased()]
                        Toggle(isOn: Binding(
                            get: { isSelected },
                            set: { enabled in
                                var next = selected
                                if enabled {
                                    if !next.contains(where: { $0.caseInsensitiveCompare(preset.model) == .orderedSame }) {
                                        next.append(preset.model)
                                    }
                                } else {
                                    next.removeAll { $0.caseInsensitiveCompare(preset.model) == .orderedSame }
                                }
                                update(next)
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(preset.model)
                                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 6)
                                    if !preset.isOnlineProvider && !isInstalled(preset.model) {
                                        StatusChip(text: "Missing", tone: .warning)
                                    }
                                    if preset.isOnlineProvider {
                                        StatusChip(text: preset.providerName, tone: .info)
                                    }
                                    if preset.isDeepSeek {
                                        StatusChip(text: "Paid API", tone: .warning)
                                    }
                                    if let decision = modelScopeDecisionChip(stats) {
                                        StatusChip(text: decision.text, tone: decision.tone)
                                    }
                                }
                                modelScopeSummary(stats)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .toggleStyle(.checkbox)
                        .help(modelScopeHelp(preset: preset, stats: stats))
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }


    @ViewBuilder
    func modelScopeSummary(_ stats: TestModelRoleStats?) -> some View {
        if let stats {
            HStack(spacing: 6) {
                Text("\(stats.attempts) runs")
                Text("score \(formatConfidence(stats.qualityScore))")
                Text("clean \(modelStatsCleanLabel(stats))")
                if modelStatsProblemCount(stats) > 0 {
                    Text("\(modelStatsProblemCount(stats)) problems")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundColor(modelScopeSummaryColor(stats))
        } else {
            Text("No benchmark data yet")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }


    func modelScopeSummaryColor(_ stats: TestModelRoleStats) -> Color {
        let clean = modelStatsCleanRate(stats) ?? 0
        if stats.attempts > 0 && clean == 0 { return .red }
        if modelStatsProblemCount(stats) > 0 || clean < 0.80 { return .orange }
        return .secondary
    }


    func modelScopeDecisionChip(_ stats: TestModelRoleStats?) -> (text: String, tone: SomaStatusTone)? {
        guard let stats else { return (text: "Untested", tone: .neutral) }
        guard stats.attempts > 0 else { return (text: "Untested", tone: .neutral) }
        let problemCount = modelStatsProblemCount(stats)
        if problemCount == stats.attempts {
            return (text: "100% problems", tone: .danger)
        }
        if stats.attempts < 5 {
            return (text: "Small sample", tone: .warning)
        }
        let clean = modelStatsCleanRate(stats) ?? 0
        if clean < 0.50 {
            return (text: "High risk", tone: .warning)
        }
        if clean >= 0.90 && (stats.qualityScore ?? 0) >= 0.86 {
            return (text: "Stable", tone: .good)
        }
        return nil
    }


    func modelScopeHelp(preset: RusToPromptModelPreset, stats: TestModelRoleStats?) -> String {
        guard let stats else {
            return "\(preset.detail)\nNo benchmark data yet. Run a small sample before keeping this model in the queue."
        }
        let problemRate = stats.attempts > 0 ? Double(modelStatsProblemCount(stats)) / Double(stats.attempts) : 0
        return [
            preset.detail,
            "Scope: \(stats.attempts) runs, \(stats.confidenceCount) usable scores.",
            "Score \(formatConfidence(stats.qualityScore)); clean \(modelStatsCleanLabel(stats)); problems \(modelStatsProblemCount(stats)) (\(formatPercent(problemRate))).",
            "Judge failed \(stats.confidenceFailedCount), run failed \(stats.pipelineFailedCount), degraded \(stats.degradedCount).",
            "Last tested \(shortDateTime(stats.lastTestedAt))."
        ]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "\n")
    }


    var queueItemsPanel: some View {
        let activeItems = queueVisibleItems
        let completedItems = queueCompletedItems
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Queue")
                    .font(.headline)
                StatusChip(
                    text: "\(activeItems.count) active · \(completedItems.count) completed",
                    tone: queueManager.items.isEmpty ? .neutral : .info
                )
                Spacer()
                Button {
                    queueManager.startNextIfPossible(allowBatteryStart: true)
                } label: {
                    Image(systemName: "play.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Start next queued test. Manual start is allowed on battery for the current run.")
                Button {
                    queueManager.isPaused ? queueManager.resume() : queueManager.pause()
                } label: {
                    Image(systemName: queueManager.isPaused ? "play.circle.fill" : "pause.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(queueManager.isPaused ? "Resume queue" : "Pause after current stage")
                Button {
                    queueManager.runNow()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Skip cooldown and continue the active run now.")
                Button {
                    queueManager.stopCurrent()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!queueManager.isRunning)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(activeItems) { item in
                        queueItemRow(item)
                    }
                    completedQueueSection(completedItems)
                }
            }
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }


    var queueVisibleItems: [RusToPromptQueueItem] {
        sortQueueItemsOldestFirst(queueManager.items.filter { $0.status != .completed })
    }


    var queueCompletedItems: [RusToPromptQueueItem] {
        sortQueueItemsNewestFirst(queueManager.items.filter { $0.status == .completed })
    }


    func sortQueueItemsOldestFirst(_ items: [RusToPromptQueueItem]) -> [RusToPromptQueueItem] {
        items.sorted { left, right in
            if left.createdAt == right.createdAt {
                return left.id < right.id
            }
            return left.createdAt < right.createdAt
        }
    }


    func sortQueueItemsNewestFirst(_ items: [RusToPromptQueueItem]) -> [RusToPromptQueueItem] {
        items.sorted { left, right in
            let leftDate = left.finishedAt ?? left.updatedAt
            let rightDate = right.finishedAt ?? right.updatedAt
            if leftDate == rightDate {
                return left.id > right.id
            }
            return leftDate > rightDate
        }
    }


    @ViewBuilder
    func completedQueueSection(_ items: [RusToPromptQueueItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    showCompletedQueueItems.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showCompletedQueueItems ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 18, height: 18)
                        Text("Completed")
                            .font(.subheadline.weight(.semibold))
                        StatusChip(text: "\(items.count)", tone: .good)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .help(showCompletedQueueItems ? "Hide completed tests" : "Show completed tests")

                if showCompletedQueueItems {
                    ForEach(items) { item in
                        queueItemRow(item)
                    }
                }
            }
            .padding(.top, 4)
        }
    }


    var queueActivePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Active")
                .font(.headline)
            SomaKeyValueRow(label: "Stage", value: queueManager.currentStage, tone: queueManager.isRunning ? .info : .neutral)
            SomaKeyValueRow(label: "Model", value: queueManager.currentModel, tone: .neutral)
            if let output = queueManager.currentOutputPath {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: output))
                } label: {
                    Label("Open Output", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            Divider()
            Text("Recent activity")
                .font(.subheadline.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(queueManager.recentActivity, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }


    func queueItemRow(_ item: RusToPromptQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            queueItemHeader(item)
            Text(item.prompt)
                .font(.caption)
                .lineLimit(3)
                .textSelection(.enabled)
            if !item.statusMessage.isEmpty {
                Text(item.statusMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if isQueueItemExpanded(item.id) {
                queueItemDetails(item)
            }
        }
        .padding(10)
        .background(Color(NSColor.textBackgroundColor).opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.10)))
    }

}

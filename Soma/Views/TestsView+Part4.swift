import SwiftUI
import AppKit
import Foundation

extension TestsView {
    func queueCandidatePanel(title: String, selected: [String], update: @escaping ([String]) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.bold())
                Spacer()
                StatusChip(text: "\(selected.count)", tone: selected.isEmpty ? .warning : .info)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(queueLocalModelRows(selected: selected), id: \.model) { preset in
                        let isSelected = selected.contains { $0.caseInsensitiveCompare(preset.model) == .orderedSame }
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
                            HStack {
                                Text(preset.model)
                                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if !isInstalled(preset.model) {
                                    StatusChip(text: "Missing", tone: .warning)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .help(preset.detail)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
    }


    var queueItemsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Queue")
                    .font(.headline)
                StatusChip(text: "\(queueManager.items.count) items", tone: queueManager.items.isEmpty ? .neutral : .info)
                Spacer()
                Button("Start") {
                    queueManager.startNextIfPossible()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(queueManager.isPaused ? "Resume" : "Pause") {
                    queueManager.isPaused ? queueManager.resume() : queueManager.pause()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Run Now") {
                    queueManager.runNow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Stop Current") {
                    queueManager.stopCurrent()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!queueManager.isRunning)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(queueManager.items) { item in
                        queueItemRow(item)
                    }
                }
            }
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
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
            HStack(spacing: 8) {
                StatusChip(text: item.status.rawValue.replacingOccurrences(of: "_", with: " "), tone: queueItemTone(item.status))
                Text(item.id)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                Spacer()
                if let output = item.outputPath {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: output))
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help(output)
                }
                Button("Retry") {
                    queueManager.retry(item)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(item.status == .running)
                Button("Remove") {
                    queueManager.remove(item)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            Text(item.prompt)
                .font(.caption)
                .lineLimit(3)
                .textSelection(.enabled)
            if !item.statusMessage.isEmpty {
                Text(item.statusMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color(NSColor.textBackgroundColor).opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.10)))
    }

}

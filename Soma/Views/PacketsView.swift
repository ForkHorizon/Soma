import Foundation
import SwiftUI

struct PacketsView: View {
    @ObservedObject var viewModel: SomaViewModel
    @Binding var selectedRoute: AppRoute?
    @State private var showFeedbackSheet = false
    @State private var feedbackPacketID: String?
    @State private var feedbackWhyNotUseful = ""
    @State private var feedbackMissedFiles = ""
    @State private var feedbackFinalOutcome = "failed"
    @State private var feedbackAgentUsedSoma = false

    var body: some View {
        SomaPage(maxWidth: 1160) {
            WorkflowHeader(
                title: "Packets",
                subtitle: "Real packet runs from the simplified UI. Test fixtures and raw logs stay out of this view.",
                icon: "tray.full",
                tone: packets.isEmpty ? .neutral : .info,
                trailing: AnyView(prepareButton)
            )

            if packets.isEmpty {
                EmptyStateView(
                    icon: "tray",
                    title: "No real packets yet",
                    subtitle: emptySubtitle,
                    actionTitle: "Prepare First Packet",
                    actionIcon: "doc.text.magnifyingglass",
                    action: { selectedRoute = .relay }
                )
            } else {
                summaryPanel
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(packets) { packet in
                        packetRow(packet)
                    }
                }
            }
        }
        .onAppear {
            viewModel.hydratePacketHistoryIfNeeded()
            viewModel.loadStructuredLogs()
            viewModel.refreshPacketLiveToolCounts()
        }
        .sheet(isPresented: $showFeedbackSheet) {
            PacketFeedbackSheet(
                title: "Why was this not useful?",
                whyNotUseful: $feedbackWhyNotUseful,
                missedFiles: $feedbackMissedFiles,
                finalOutcome: $feedbackFinalOutcome,
                agentUsedSoma: $feedbackAgentUsedSoma,
                onCancel: {
                    showFeedbackSheet = false
                },
                onSave: {
                    if let feedbackPacketID {
                        viewModel.markPacketFeedback(
                            feedbackPacketID,
                            useful: false,
                            whyNotUseful: feedbackWhyNotUseful,
                            missedFilesText: feedbackMissedFiles,
                            finalOutcome: feedbackFinalOutcome,
                            agentUsedSoma: feedbackAgentUsedSoma
                        )
                    }
                    showFeedbackSheet = false
                }
            )
        }
    }

    private var prepareButton: some View {
        Button {
            selectedRoute = .relay
        } label: {
            Label("Prepare Packet", systemImage: "doc.text.magnifyingglass")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    private var summaryPanel: some View {
        SomaPanel(title: "Is Soma useful?", subtitle: "Success is three real tasks where packet plus live Soma context saved time.", icon: "hand.thumbsup", tone: usefulProofCount == 3 ? .good : .warning) {
            if usefulProofCount == 0 {
                StatusBanner(title: "Soma has not proven usefulness yet", detail: "Run real tasks, use at least one live Soma tool when context is missing, then mark the outcome honestly.", tone: .warning)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                MetricTile(title: "3-task proof", value: "\(usefulProofCount)/3", detail: "useful packets", tone: usefulProofCount == 3 ? .good : .warning)
                MetricTile(title: "Runs", value: "\(packets.count)", detail: "selected project", tone: .info)
                MetricTile(title: "Useful", value: "\(packets.filter { $0.usefulness == "useful" }.count)", detail: "marked helpful", tone: .good)
                MetricTile(title: "Not useful", value: "\(packets.filter { $0.usefulness == "not_useful" }.count)", detail: "needs product work", tone: .warning)
                MetricTile(title: "Live Soma", value: "\(packets.filter { $0.agentUsedSoma || viewModel.liveToolCallCount(for: $0) > 0 }.count)", detail: "runs with tool calls", tone: .info)
                MetricTile(title: "Unreviewed", value: "\(packets.filter { $0.usefulness == nil }.count)", detail: "mark after trying", tone: .neutral)
            }
        }
    }

    private func packetRow(_ packet: PacketHistoryItem) -> some View {
        let liveCalls = viewModel.liveToolCallCount(for: packet)
        return SomaPanel(
            title: packet.prompt,
            subtitle: "\(packet.projectName) · \(dateLabel(packet.createdAt))",
            icon: feedbackIcon(packet),
            tone: feedbackTone(packet),
            trailing: AnyView(feedbackControls(packet))
        ) {
            HStack(spacing: 8) {
                StatusChip(text: packet.status, tone: packet.status == "ok" ? .good : .warning)
                if let mode = packet.packetMode {
                    StatusChip(text: mode, tone: .neutral)
                }
                if let tokens = packet.estimatedTokens {
                    StatusChip(text: "\(tokens) tok", tone: .neutral)
                }
                if let run = packet.auditRunID {
                    StatusChip(text: String(run.prefix(10)), tone: .info)
                }
                StatusChip(text: liveCalls > 0 ? "Live Soma \(liveCalls)" : "No live tools", tone: liveCalls > 0 || packet.agentUsedSoma ? .good : .neutral)
                StatusChip(text: "Outcome \(packet.finalOutcome)", tone: outcomeTone(packet.finalOutcome))
            }

            if !packet.warnings.isEmpty {
                StatusBanner(title: "Warnings", detail: packet.warnings.prefix(3).joined(separator: "\n"), tone: .warning)
            }

            if packet.usefulness == "not_useful" {
                let reason = packet.whyNotUseful?.trimmingCharacters(in: .whitespacesAndNewlines)
                StatusBanner(
                    title: "Quality problem",
                    detail: (reason?.isEmpty == false ? reason! : "No reason recorded yet.") + missedFilesSummary(packet),
                    tone: .warning
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("What Soma selected and why")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                if packet.evidencePaths.isEmpty {
                    Text("No files recorded for this packet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(packet.evidencePaths.prefix(8).enumerated()), id: \.offset) { index, path in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent)
                                    .font(.caption.bold())
                                Text(path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let summary = evidenceSummary(packet, index: index) {
                                    Text(summary)
                                        .font(.caption2)
                                        .foregroundColor(.primary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func evidenceSummary(_ packet: PacketHistoryItem, index: Int) -> String? {
        guard let summaries = packet.evidenceSummaries, summaries.indices.contains(index) else { return nil }
        return summaries[index]
    }

    private func feedbackControls(_ packet: PacketHistoryItem) -> some View {
        HStack(spacing: 6) {
            Button {
                viewModel.markPacketFeedback(
                    packet.id,
                    useful: true,
                    whyNotUseful: nil,
                    missedFilesText: nil,
                    finalOutcome: "useful",
                    agentUsedSoma: packet.agentUsedSoma || viewModel.liveToolCallCount(for: packet) > 0
                )
            } label: {
                Image(systemName: packet.usefulness == "useful" ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Mark packet useful")

            Button {
                openFeedback(for: packet)
            } label: {
                Image(systemName: packet.usefulness == "not_useful" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Mark packet not useful")
        }
    }

    private var packets: [PacketHistoryItem] {
        viewModel.packetsForSelectedProject()
    }

    private var usefulProofCount: Int {
        min(3, packets.filter { $0.usefulness == "useful" }.count)
    }

    private var emptySubtitle: String {
        if viewModel.selectedProjectRoot.isEmpty {
            return "Choose a project and prepare one packet. This page will show only packet runs created from the app."
        }
        return "Prepare a packet for \((viewModel.selectedProjectRoot as NSString).lastPathComponent). This page intentionally hides fixture logs and diagnostics noise."
    }

    private func feedbackTone(_ packet: PacketHistoryItem) -> SomaStatusTone {
        switch packet.usefulness {
        case "useful": return .good
        case "not_useful": return .warning
        default: return .neutral
        }
    }

    private func feedbackIcon(_ packet: PacketHistoryItem) -> String {
        switch packet.usefulness {
        case "useful": return "hand.thumbsup.fill"
        case "not_useful": return "hand.thumbsdown.fill"
        default: return "tray.full"
        }
    }

    private func outcomeTone(_ outcome: String) -> SomaStatusTone {
        switch outcome {
        case "useful": return .good
        case "partial": return .warning
        case "failed": return .danger
        default: return .neutral
        }
    }

    private func missedFilesSummary(_ packet: PacketHistoryItem) -> String {
        guard !packet.missedFiles.isEmpty else { return "" }
        return "\nMissed files: " + packet.missedFiles.prefix(6).joined(separator: ", ")
    }

    private func openFeedback(for packet: PacketHistoryItem) {
        feedbackPacketID = packet.id
        feedbackWhyNotUseful = packet.whyNotUseful ?? ""
        feedbackMissedFiles = packet.missedFiles.joined(separator: "\n")
        feedbackFinalOutcome = packet.finalOutcome == "unknown" || packet.finalOutcome == "useful" ? "failed" : packet.finalOutcome
        feedbackAgentUsedSoma = packet.agentUsedSoma || viewModel.liveToolCallCount(for: packet) > 0
        showFeedbackSheet = true
    }

    private func dateLabel(_ raw: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: raw) else { return raw }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct PacketFeedbackSheet: View {
    let title: String
    @Binding var whyNotUseful: String
    @Binding var missedFiles: String
    @Binding var finalOutcome: String
    @Binding var agentUsedSoma: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("What did Soma miss?")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                TextEditor(text: $missedFiles)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 72)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Why did it not help?")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                TextEditor(text: $whyNotUseful)
                    .frame(minHeight: 96)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
            }

            Picker("Final outcome", selection: $finalOutcome) {
                Text("Failed").tag("failed")
                Text("Partial").tag("partial")
                Text("Unknown").tag("unknown")
            }
            .pickerStyle(.segmented)

            Toggle("Codex used live Soma tools after the packet", isOn: $agentUsedSoma)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save Feedback", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

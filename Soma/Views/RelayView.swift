import AppKit
import SwiftUI

struct RelayView: View {
    @ObservedObject var viewModel: RelayViewModel
    @ObservedObject var somaViewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager
    @State private var showEvidence = true
    @State private var showAdvanced = false
    @State private var packetCopied = false
    @State private var codexProtocolCopied = false
    @State private var preparedTask = ""
    @State private var showNotUsefulFeedback = false
    @State private var feedbackPacketID: String?
    @State private var feedbackWhyNotUseful = ""
    @State private var feedbackMissedFiles = ""
    @State private var feedbackFinalOutcome = "failed"
    @State private var feedbackAgentUsedSoma = false

    var body: some View {
        SomaPage(maxWidth: 1160) {
            WorkflowHeader(
                title: "Prepare Packet",
                subtitle: "Choose a project, describe one coding task, then copy the compact evidence packet into Codex, Claude, Gemini, or Hermes.",
                icon: "doc.text.magnifyingglass",
                tone: somaViewModel.selectedProjectRoot.isEmpty ? .warning : .info
            )

            taskPanel

            if let error = viewModel.relayError {
                StatusBanner(title: "Packet preparation failed", detail: error, tone: .danger)
            }

            if relayIsBusy {
                StatusBanner(
                    title: "Preparing packet",
                    detail: "Soma is scanning project files, git state, logs, and task-specific evidence. Optional systems stay in Diagnostics.",
                    tone: .info,
                    isLoading: true
                )
            }

            if let bundle = viewModel.gatherBundle, bundle.error == nil {
                resultPanel(bundle)
            } else if !relayIsBusy {
                nextStepPanel
            }
        }
        .sheet(isPresented: $showNotUsefulFeedback) {
            PacketFeedbackSheet(
                title: "Why was this not useful?",
                whyNotUseful: $feedbackWhyNotUseful,
                missedFiles: $feedbackMissedFiles,
                finalOutcome: $feedbackFinalOutcome,
                agentUsedSoma: $feedbackAgentUsedSoma,
                onCancel: {
                    showNotUsefulFeedback = false
                },
                onSave: {
                    if let feedbackPacketID {
                        somaViewModel.markPacketFeedback(
                            feedbackPacketID,
                            useful: false,
                            whyNotUseful: feedbackWhyNotUseful,
                            missedFilesText: feedbackMissedFiles,
                            finalOutcome: feedbackFinalOutcome,
                            agentUsedSoma: feedbackAgentUsedSoma
                        )
                    }
                    showNotUsefulFeedback = false
                }
            )
        }
    }

    private var taskPanel: some View {
        SomaPanel(
            title: "What do you need help with?",
            subtitle: "Use natural language. Concrete bug, review, refactor, or UI task works best.",
            icon: "square.and.pencil",
            tone: .info
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StatusChip(text: projectLabel, tone: somaViewModel.selectedProjectRoot.isEmpty ? .warning : .good, icon: "folder")
                    StatusChip(text: setupLabel, tone: setupTone, icon: setupTone == .good ? "checkmark.seal" : "exclamationmark.triangle")
                    Spacer()
                    Button {
                        chooseProjectRoot()
                    } label: {
                        Label(somaViewModel.selectedProjectRoot.isEmpty ? "Choose Project" : "Change", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                ZStack(alignment: .topLeading) {
                    if viewModel.relayPrompt.isEmpty {
                        Text("Example: Review the new sidebar reset and find UI friction before I use Soma for real work.")
                            .foregroundColor(.secondary)
                            .padding(.leading, 8)
                            .padding(.top, 9)
                            .font(.body)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: $viewModel.relayPrompt)
                        .font(.body)
                        .frame(minHeight: 132, idealHeight: 150, maxHeight: 190)
                        .padding(4)
                        .background(Color.clear)
                        .accessibilityLabel(Text("Describe one coding task."))
                }
                .background(Color(NSColor.textBackgroundColor).opacity(0.86))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.20)))

                HStack(spacing: 10) {
                    Text(actionHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Clear") {
                        viewModel.resetState(somaViewModel: somaViewModel)
                        packetCopied = false
                        codexProtocolCopied = false
                        preparedTask = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button {
                        packetCopied = false
                        codexProtocolCopied = false
                        preparedTask = viewModel.relayPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        viewModel.runRelay(ollama: ollama, somaViewModel: somaViewModel)
                    } label: {
                        Label("Prepare", systemImage: "doc.text.magnifyingglass")
                            .bold()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(relayActionDisabled)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
    }

    private var nextStepPanel: some View {
        SomaPanel(title: "Simple flow", subtitle: "Everything else is intentionally behind Diagnostics.", icon: "1.circle", tone: .neutral) {
            StepChecklist(steps: [
                WorkflowStep(id: "project", title: "1. Project", detail: somaViewModel.selectedProjectRoot.isEmpty ? "Choose a folder." : projectLabel, tone: somaViewModel.selectedProjectRoot.isEmpty ? .warning : .good),
                WorkflowStep(id: "task", title: "2. Task", detail: "Describe one coding task.", tone: .neutral),
                WorkflowStep(id: "packet", title: "3. Packet", detail: "Copy selected evidence into your coding model.", tone: .neutral),
                WorkflowStep(id: "feedback", title: "4. Feedback", detail: "Mark useful or not useful.", tone: .neutral),
            ])
        }
    }

    private func resultPanel(_ bundle: GatherBundle) -> some View {
        let packet = bundle.codex_packet ?? bundle.enriched_prompt ?? ""
        let warnings = packetWarnings(bundle)
        return VStack(alignment: .leading, spacing: 14) {
            SomaPanel(
                title: resultTitle(bundle),
                subtitle: "Copy this packet into the coding model. Review selected files first if warnings appear.",
                icon: resultTone(bundle).symbol,
                tone: resultTone(bundle)
            ) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    MetricTile(title: "Evidence", value: "\(bundle.evidence_items?.count ?? 0)", detail: "selected files/logs", tone: .info)
                    MetricTile(title: "Packet", value: bundle.estimated_tokens.map { "\($0)" } ?? "-", detail: "estimated tokens", tone: .neutral)
                    MetricTile(title: "Mode", value: bundle.packet_mode ?? "task", detail: "packet route", tone: .neutral)
                    MetricTile(title: "Warnings", value: "\(warnings.count)", detail: "review before use", tone: warnings.isEmpty ? .good : .warning)
                }

                if !warnings.isEmpty {
                    StatusBanner(title: "Review before copying", detail: warnings.prefix(4).joined(separator: "\n"), tone: .warning)
                }

                HStack(spacing: 10) {
                    Button {
                        copyToClipboard(packet)
                        packetCopied = true
                    } label: {
                        Label(packetCopied ? "Copied" : "Copy Packet", systemImage: packetCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(packet.isEmpty)

                    if let id = viewModel.lastPacketHistoryID {
                        Button {
                            copyToClipboard(codexLiveProtocol(bundle: bundle))
                            codexProtocolCopied = true
                        } label: {
                            Label(codexProtocolCopied ? "Codex Protocol Copied" : "Use with Codex", systemImage: codexProtocolCopied ? "checkmark.circle.fill" : "terminal")
                        }
                        .buttonStyle(.bordered)
                        .disabled(packet.isEmpty)

                        Button {
                            somaViewModel.markPacketUsefulness(id, useful: true)
                        } label: {
                            Label("Useful", systemImage: "hand.thumbsup")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            openNotUsefulFeedback(for: id)
                        } label: {
                            Label("Not useful", systemImage: "hand.thumbsdown")
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    Button {
                        showAdvanced.toggle()
                    } label: {
                        Label(showAdvanced ? "Hide Details" : "Details", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }

            evidencePanel(bundle)

            packetPreview(packet)

            if showAdvanced {
                advancedPanel(bundle)
            }
        }
    }

    private func evidencePanel(_ bundle: GatherBundle) -> some View {
        DetailDisclosure(
            title: "Selected Files",
            subtitle: "\(bundle.evidence_items?.count ?? 0) item(s) Soma chose for this task",
            icon: "tray.full",
            isExpanded: $showEvidence
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if let evidence = bundle.evidence_items, !evidence.isEmpty {
                    ForEach(Array(evidence.enumerated()), id: \.offset) { _, item in
                        EvidenceRow(item: item)
                    }
                } else {
                    Text("No selected evidence was returned.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func packetPreview(_ packet: String) -> some View {
        SomaPanel(title: "Packet Preview", subtitle: "\(packet.count) characters", icon: "doc.plaintext", tone: .neutral) {
            Text(packet.isEmpty ? "No packet text returned." : packet)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(NSColor.textBackgroundColor).opacity(0.86))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func advancedPanel(_ bundle: GatherBundle) -> some View {
        SomaPanel(title: "Advanced Details", subtitle: "Kept out of the first layer.", icon: "slider.horizontal.3", tone: .neutral) {
            SomaKeyValueRow(label: "Audit", value: bundle.audit?.run_id ?? "none", tone: bundle.audit?.run_id == nil ? .neutral : .info)
            SomaKeyValueRow(label: "Project type", value: bundle.project_type ?? "unknown", tone: .neutral)
            SomaKeyValueRow(label: "Analysis depth", value: bundle.analysis_depth ?? "deterministic", tone: .neutral)
            SomaKeyValueRow(label: "Language", value: languageBadge(bundle.language_optimization), tone: bundle.language_optimization?.status == "failed_fallback" ? .warning : .neutral)
            if let omitted = bundle.omitted_context, !omitted.isEmpty {
                Text("Omitted context: \(omitted.keys.sorted().joined(separator: ", "))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var relayActionDisabled: Bool {
        relayIsBusy || somaViewModel.selectedProjectRoot.isEmpty || viewModel.relayPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var relayIsBusy: Bool {
        viewModel.relayPhase == .gathering || viewModel.relayPhase == .relaying
    }

    private var actionHint: String {
        if somaViewModel.selectedProjectRoot.isEmpty { return "Choose a project first." }
        if viewModel.relayPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Describe the task to continue." }
        return "Command-Return prepares the packet."
    }

    private var projectLabel: String {
        guard !somaViewModel.selectedProjectRoot.isEmpty else { return "No project" }
        return (somaViewModel.selectedProjectRoot as NSString).lastPathComponent
    }

    private var setupLabel: String {
        guard !somaViewModel.selectedProjectRoot.isEmpty else { return "Needs project" }
        return somaViewModel.projectHealthWarningCount(for: somaViewModel.selectedProjectRoot) == 0 ? "Ready" : "Needs setup"
    }

    private var setupTone: SomaStatusTone {
        guard !somaViewModel.selectedProjectRoot.isEmpty else { return .warning }
        return somaViewModel.projectHealthWarningCount(for: somaViewModel.selectedProjectRoot) == 0 ? .good : .warning
    }

    private func resultTone(_ bundle: GatherBundle) -> SomaStatusTone {
        if (bundle.evidence_items?.count ?? 0) == 0 { return .warning }
        return packetWarnings(bundle).isEmpty ? .good : .warning
    }

    private func resultTitle(_ bundle: GatherBundle) -> String {
        if (bundle.evidence_items?.count ?? 0) == 0 { return "Packet prepared with no selected files" }
        return packetWarnings(bundle).isEmpty ? "Packet ready" : "Packet ready with warnings"
    }

    private func packetWarnings(_ bundle: GatherBundle) -> [String] {
        var warnings: [String] = []
        if bundle.audit?.evidence_quality?.status == "degraded" {
            warnings.append("Evidence quality is degraded.")
        }
        warnings.append(contentsOf: bundle.audit?.evidence_quality?.warnings ?? [])
        warnings.append(contentsOf: bundle.audit?.missing_evidence?.quality_warnings ?? [])
        warnings.append(contentsOf: bundle.collection_plan_warnings ?? [])
        warnings.append(contentsOf: bundle.collection_plan?.warnings ?? [])
        warnings.append(contentsOf: bundle.estimated_context_reduction?.warnings ?? [])
        let deduped = Array(NSOrderedSet(array: warnings.filter { !$0.isEmpty })) as? [String] ?? warnings
        return deduped
    }

    private func languageBadge(_ language: LanguageOptimization?) -> String {
        guard let language else { return "not checked" }
        let source = (language.source_language ?? "?").uppercased()
        let target = (language.target_language ?? "en").uppercased()
        if language.status == "translated" { return "\(source) -> \(target)" }
        if language.status == "failed_fallback" { return "\(source) fallback" }
        if language.status == "original_english" { return "EN prompt" }
        return language.status ?? "unknown"
    }

    private func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Project Root"
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        somaViewModel.selectProjectRoot(path)
    }

    private func openNotUsefulFeedback(for id: String) {
        feedbackPacketID = id
        feedbackWhyNotUseful = ""
        feedbackMissedFiles = ""
        feedbackFinalOutcome = "failed"
        feedbackAgentUsedSoma = false
        showNotUsefulFeedback = true
    }

    private func codexLiveProtocol(bundle: GatherBundle) -> String {
        let projectRoot = bundle.project_root ?? somaViewModel.selectedProjectRoot
        let runID = bundle.audit?.run_id ?? "paste-run-id-if-known"
        let taskID = bundle.audit?.task_id ?? "paste-task-id-if-known"
        let task = preparedTask.isEmpty ? (bundle.original_prompt ?? "current Soma packet task") : preparedTask
        return """
        Use Soma as the Codex-first context helper for this task.

        Project root: \(projectRoot)
        Task: \(task)
        Soma run_id: \(runID)
        Soma task_id: \(taskID)

        Protocol:
        1. Start from the copied Soma packet; do not re-scan the whole repo unless evidence is degraded.
        2. If context is missing, call soma_code_context with run_id "\(runID)", task_id "\(taskID)", client "codex", workflow "live_mcp".
        3. For bugs, call soma_debug before guessing.
        4. After edits or tests, call soma_delta with the same run_id/task_id/client/workflow.
        5. Before final answer or review, call soma_review when regressions or missing tests matter.
        6. Use soma_apply only when it is the right audited write path; summarize every change it makes.
        """
    }
}

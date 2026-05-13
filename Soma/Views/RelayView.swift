import SwiftUI
import AppKit

struct RelayView: View {
    @ObservedObject var viewModel: RelayViewModel
    @ObservedObject var somaViewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if viewModel.relayPhase == .idle && viewModel.gatherBundle == nil && viewModel.relayResponse == nil && viewModel.relayError == nil {
                        emptyState(icon: "doc.text.magnifyingglass", title: "Evidence compiler", subtitle: "Prepare compact Codex packets from project files, logs, and git changes.")
                    }
                    if viewModel.relayPhase == .gathering {
                        phaseCard(emoji: "📦", title: "Compiling evidence…", subtitle: "Scanning deterministic project signals, logs, symbols, and git summaries", color: .orange)
                    }
                    if viewModel.relayPhase == .relaying {
                        phaseCard(emoji: "🧠", title: "Running optional local analysis…", subtitle: "Using \(ollama.modelName) on the compact packet only", color: .blue)
                    }
                    if let bundle = viewModel.gatherBundle, bundle.error == nil { bundlePanel(bundle) }
                    if let relay = viewModel.relayResponse { answerPanel(relay) }
                    if let relayError = viewModel.relayError { Text("⚠️ \(relayError)").foregroundColor(.red).padding() }

                    if !somaViewModel.activityLogs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Button(action: { withAnimation { somaViewModel.showActivityLog.toggle() } }) {
                                HStack {
                                    Image(systemName: somaViewModel.showActivityLog ? "chevron.down" : "chevron.right")
                                    Text("📝 Activity Log (\(somaViewModel.activityLogs.count))").font(.subheadline.bold())
                                    Spacer()
                                    Button("Copy Log") { copyToClipboard(somaViewModel.activityLogs.joined(separator: "\n")) }.buttonStyle(.plain).font(.caption).foregroundColor(.blue)
                                }
                            }.buttonStyle(.plain)
                            if somaViewModel.showActivityLog {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(somaViewModel.activityLogs, id: \.self) { log in
                                        Text(log).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.padding(10).background(Color.secondary.opacity(0.1)).cornerRadius(8)
                            }
                        }.padding(.top, 8)
                    }
                }.padding()
            }
            .background(Color(NSColor.textBackgroundColor).opacity(0.5)).padding()

            inputBar(text: $viewModel.relayPrompt, placeholder: "Describe the bug or task; Soma will prepare a compact Codex packet", disabled: relayIsBusy, buttonLabel: "Prepare Packet", icon: "doc.text.magnifyingglass") {
                viewModel.runRelay(ollama: ollama, somaViewModel: somaViewModel)
            }
        }
    }

    private var relayIsBusy: Bool { viewModel.relayPhase == .gathering || viewModel.relayPhase == .relaying }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer(minLength: 60)
            Image(systemName: icon).font(.system(size: 44)).foregroundColor(.secondary.opacity(0.4))
            Text(title).font(.title3).bold()
            Text(subtitle).foregroundColor(.secondary).multilineTextAlignment(.center)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private func phaseCard(emoji: String, title: String, subtitle: String, color: Color) -> some View {
        HStack(spacing: 14) {
            Text(emoji).font(.system(size: 30))
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundColor(.secondary) }
            Spacer(); ProgressView().controlSize(.regular)
        }.padding(14).background(color.opacity(0.08)).overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.25))).cornerRadius(10)
    }

    private func bundlePanel(_ bundle: GatherBundle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { withAnimation { viewModel.showContextPanel.toggle() } }) {
                HStack {
                    Image(systemName: viewModel.showContextPanel ? "chevron.down" : "chevron.right").foregroundColor(.secondary)
                    Text("📦 Codex Packet").font(.headline)
                    Spacer()
                    if bundle.codex_packet != nil || bundle.enriched_prompt != nil {
                        Button(action: { copyToClipboard(bundle.codex_packet ?? bundle.enriched_prompt ?? "") }) { Label("Copy Packet", systemImage: "doc.on.doc") }.buttonStyle(BorderedButtonStyle()).controlSize(.small)
                    }
                    if let summary = bundle.context_summary { Text(summary).font(.caption).foregroundColor(.secondary).lineLimit(2) }
                }
            }.buttonStyle(.plain)
            if viewModel.showContextPanel {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        if let routing = bundle.routing_decision { badge(text: routing.replacingOccurrences(of: "_", with: " ")) }
                        if let packetMode = bundle.packet_mode { badge(text: "mode \(packetMode)") }
                        if let analysisDepth = bundle.analysis_depth { badge(text: "depth \(analysisDepth)") }
                        if let projectType = bundle.project_type { badge(text: projectType) }
                        if let confidence = bundle.confidence { badge(text: String(format: "confidence %.2f", confidence)) }
                        if let tokenBudget = bundle.token_budget { badge(text: "budget \(tokenBudget)") }
                        if let estimatedTokens = bundle.estimated_tokens { badge(text: "~\(estimatedTokens) tokens") }
                        if let savings = bundle.operation_savings?.savings_pct ?? bundle.token_savings?.savings_pct {
                            badge(text: String(format: "%.1f%% ops", savings))
                        }
                    }
                    if let reason = bundle.gather_reason { labeledBlock(title: "Why This Route", text: reason) }
                    if let root = bundle.project_root { labeledBlock(title: "Project Root", text: root) }
                    if let gitStatus = bundle.git_status, !gitStatus.isEmpty { labeledBlock(title: "Git Status", text: gitStatus) }
                    if let diffSummary = bundle.git_diff_summary {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Git Diff Summary").font(.subheadline).bold()
                            diffSummaryView(diffSummary)
                        }
                    }
                    if let repoIndex = bundle.repo_index {
                        labeledBlock(title: "Repo Index", text: repoIndexSummary(repoIndex))
                    }
                    if let stages = bundle.analysis_stages, !stages.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Analysis Stages").font(.subheadline).bold()
                            ForEach(Array(stages.enumerated()), id: \.offset) { _, stage in
                                Text(stageSummary(stage)).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    if let assumptions = bundle.assumptions, !assumptions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Assumptions").font(.subheadline).bold()
                            ForEach(assumptions, id: \.self) { item in Text("• \(item)").font(.caption).foregroundColor(.secondary) }
                        }
                    }
                    if let evidence = bundle.evidence_items, !evidence.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Evidence (\(evidence.count))").font(.subheadline).bold()
                            ForEach(Array(evidence.enumerated()), id: \.offset) { _, item in evidenceRow(item) }
                        }
                    }
                    if let errors = bundle.error_lines, !errors.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Detected Errors (\(errors.count))").font(.subheadline).bold()
                            ForEach(errors.prefix(6), id: \.self) { line in Text(line).font(.system(.caption, design: .monospaced)).foregroundColor(.red) }
                        }
                    }
                    if let omitted = bundle.omitted_context, !omitted.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Omitted Context").font(.subheadline).bold()
                            ForEach(omitted.keys.sorted(), id: \.self) { key in
                                Text("\(key): \(omitted[key]?.displayValue ?? "")").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    if let packet = bundle.codex_packet ?? bundle.enriched_prompt, !packet.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Packet Preview").font(.subheadline).bold()
                            Text(packet).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary).lineLimit(28).textSelection(.enabled).padding(8).background(Color(NSColor.textBackgroundColor)).cornerRadius(8)
                        }
                    }
                }.padding(10).background(Color(NSColor.controlBackgroundColor)).cornerRadius(8)
            }
        }.padding(12).background(Color.green.opacity(0.06)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.2))).cornerRadius(10)
    }

    private func evidenceRow(_ item: EvidenceItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) { Text(item.kind?.uppercased() ?? "FILE").font(.caption2.bold()).foregroundColor(.secondary); Text(URL(fileURLWithPath: item.path ?? "").lastPathComponent).font(.caption.bold()) }
            Text(item.path ?? "").font(.caption2).foregroundColor(.secondary).textSelection(.enabled)
            if let startLine = item.start_line {
                Text("Lines \(startLine)\(item.end_line.map { "-\($0)" } ?? "")").font(.caption2).foregroundColor(.secondary)
            }
            if let reason = item.reason { Text(reason).font(.caption) }
            if let symbols = item.symbols, !symbols.isEmpty {
                Text("Symbols: \(symbols.prefix(8).joined(separator: ", "))").font(.caption2).foregroundColor(.secondary)
            }
            if let refs = item.unity_refs, !refs.isEmpty {
                Text("Unity refs: \(refs.prefix(5).joined(separator: ", "))").font(.caption2).foregroundColor(.secondary)
            }
            if let preview = item.preview, !preview.isEmpty { Text(preview).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary).lineLimit(8) }
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color(NSColor.textBackgroundColor)).cornerRadius(8)
    }

    private func answerPanel(_ relay: RelayResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("🧠 Local model says").font(.headline); Spacer()
                if let routing = relay.routing_decision { badge(text: routing.replacingOccurrences(of: "_", with: " ")) }
                if let model = relay.model { Label(model, systemImage: "cpu.fill").font(.caption).foregroundColor(.secondary) }
                else if let source = relay.source { Label(source, systemImage: "bolt.fill").font(.caption).foregroundColor(.secondary) }
            }
            Divider()
            if let response = relay.response { Text(response).font(.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            if let error = relay.error { Text("Error: \(error)").foregroundColor(.red) }
        }.padding(14).background(Color.blue.opacity(0.06)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.2))).cornerRadius(10)
    }

    private func diffSummaryView(_ summary: GitDiffSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Changed files: \(summary.changed_file_count ?? summary.changed_files?.count ?? 0), raw diff omitted: \(summary.raw_diff_chars_omitted ?? 0) chars")
                .font(.caption)
                .foregroundColor(.secondary)
            if let files = summary.changed_files, !files.isEmpty {
                ForEach(Array(files.prefix(8).enumerated()), id: \.offset) { _, file in
                    Text("- \(file.status ?? "?") \(file.path ?? "") \(file.added.map { "+\($0)" } ?? "")\(file.removed.map { "/-\($0)" } ?? "")")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            if let hunks = summary.hunks, !hunks.isEmpty {
                Divider()
                ForEach(Array(hunks.prefix(6).enumerated()), id: \.offset) { index, hunk in
                    Text("\(index + 1). \(hunk.file ?? "[unknown]")\(hunk.start_line.map { ":\($0)" } ?? "") (+\(hunk.added ?? 0)/-\(hunk.removed ?? 0))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
    }

    private func badge(text: String) -> some View {
        Text(text).font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 4).background(Color.secondary.opacity(0.12)).cornerRadius(999)
    }

    private func labeledBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.subheadline).bold(); Text(text).font(.caption).foregroundColor(.secondary).textSelection(.enabled) }
    }

    private func repoIndexSummary(_ index: RepoIndexSummary) -> String {
        [
            "Cache: \(index.cache_path ?? "[none]")",
            "Indexed files: \(index.indexed_file_count ?? 0)",
            "Changed index entries: \(index.changed_index_entries ?? 0)",
        ].joined(separator: "\n")
    }

    private func stageSummary(_ stage: AnalysisStage) -> String {
        var parts = [stage.stage ?? "stage", stage.status ?? "unknown"]
        if let model = stage.model { parts.append(model) }
        if let error = stage.error, !error.isEmpty { parts.append("error: \(error)") }
        if let notes = stage.notes, !notes.isEmpty { parts.append(notes.prefix(2).joined(separator: "; ")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func inputBar(text: Binding<String>, placeholder: String, disabled: Bool, buttonLabel: String, icon: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty { Text(placeholder).foregroundColor(.secondary).padding(.leading, 5).padding(.top, 8).font(.body).allowsHitTesting(false).accessibilityHidden(true) }
                TextEditor(text: text).font(.body).frame(minHeight: 60, maxHeight: 100).padding(4).background(Color.clear)
                    .accessibilityLabel(Text(placeholder))
                    .onSubmit { if !disabled { action() } }
            }.background(Color(NSColor.controlBackgroundColor)).cornerRadius(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
            HStack {
                Button("Clear", action: { viewModel.resetState(somaViewModel: somaViewModel) }).buttonStyle(BorderedButtonStyle()).controlSize(.small).help("Clear current state")
                Spacer()
                Button(action: action) { HStack { Image(systemName: icon); Text(buttonLabel) }.bold().padding(.horizontal, 8) }
                    .buttonStyle(BorderedProminentButtonStyle())
                    .controlSize(.regular)
                    .disabled(disabled || text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(disabled ? "Currently unavailable" : (text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter a prompt to continue" : "Submit (⌘ ↵)"))
            }
        }.padding()
    }

    private func copyToClipboard(_ text: String) { let pb = NSPasteboard.general; pb.clearContents(); pb.setString(text, forType: .string) }
}

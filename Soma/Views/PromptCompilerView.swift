import AppKit
import SwiftUI

struct PromptCompilerView: View {
    @ObservedObject var viewModel: PromptCompilerViewModel
    @ObservedObject var somaViewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager
    @State private var showEvidence = true
    @State private var showPlan = false
    @State private var showActivity = false

    var body: some View {
        VStack(spacing: 0) {
            SomaPage {
                WorkflowHeader(
                    title: "Prompt Builder",
                    subtitle: "Paste an unclear task or bug report. Soma gathers local evidence and returns a stronger prompt with context, constraints, warnings, and audit metadata.",
                    icon: "wand.and.stars",
                    tone: .info
                )

                SomaPanel(title: "Workflow", subtitle: "Prompt Builder is secondary to Prepare Packet, but uses the same evidence language.", icon: "list.bullet.rectangle", tone: .info) {
                    StepChecklist(steps: workflowSteps)
                }

                if somaViewModel.selectedProjectRoot.isEmpty {
                    StatusBanner(
                        title: "Choose a project first",
                        detail: "Prompt Builder needs a project root so it can turn vague task text into a grounded prompt.",
                        tone: .warning
                    )
                }

                if isBusy {
                    StatusBanner(
                        title: "Building a stronger prompt",
                        detail: "Planning collection with \(ollama.rankerModelName), gathering focused evidence, checking quality, and running analyst mode with \(ollama.analystModelName) when available.",
                        tone: .warning,
                        isLoading: true
                    )
                }

                if let error = viewModel.errorMessage {
                    StatusBanner(title: "Prompt build failed", detail: error, tone: .danger)
                }

                if let bundle = viewModel.gatherBundle, bundle.error == nil {
                    strongPromptPanel(bundle)
                    warningsPanel(bundle)
                    evidencePanel(bundle)
                    planPanel(bundle)
                } else if viewModel.phase == .idle {
                    SomaPanel(title: "Rough Prompt In, Strong Prompt Out", subtitle: "Use this when the task is too vague for another model to act on directly.", icon: "wand.and.stars", tone: .info) {
                        EmptyStateView(
                            icon: "wand.and.stars",
                            title: "Use this when the task is too vague",
                            subtitle: "Describe the symptom, rough idea, file, page, or error. Soma will produce a prompt that is specific enough for another model to act on."
                        )
                    }
                }

                ActivityLogPanel(logs: somaViewModel.activityLogs, isExpanded: $showActivity)
            }

            PromptInputBar(
                text: $viewModel.weakPrompt,
                placeholder: "Paste a rough task, bug report, console error, page name, or symptom...",
                buttonLabel: "Build Prompt",
                icon: "wand.and.stars",
                disabled: isBusy || somaViewModel.selectedProjectRoot.isEmpty,
                disabledReason: disabledReason,
                minHeight: 64,
                onClear: { viewModel.resetState(somaViewModel: somaViewModel) }
            ) {
                viewModel.compilePrompt(somaViewModel: somaViewModel, ollama: ollama)
            }
        }
    }

    private var isBusy: Bool {
        if case .gathering = viewModel.phase { return true }
        return false
    }

    private var disabledReason: String? {
        if somaViewModel.selectedProjectRoot.isEmpty {
            return "Choose a project in the sidebar first."
        }
        if isBusy {
            return "Soma is already building a prompt."
        }
        return nil
    }

    private var workflowSteps: [WorkflowStep] {
        [
            WorkflowStep(
                id: "rough",
                title: "1. Rough Prompt",
                detail: viewModel.gatherBundle == nil ? "Paste the unclear request." : "Original request captured.",
                tone: viewModel.gatherBundle == nil ? .neutral : .good
            ),
            WorkflowStep(
                id: "plan",
                title: "2. Plan",
                detail: viewModel.gatherBundle?.collection_plan?.task_type ?? "Soma chooses evidence needs.",
                tone: viewModel.gatherBundle?.collection_plan == nil ? .neutral : .good
            ),
            WorkflowStep(
                id: "evidence",
                title: "3. Evidence",
                detail: isBusy ? "Gathering project context." : "\(viewModel.gatherBundle?.evidence_items?.count ?? 0) items selected.",
                tone: isBusy ? .warning : (viewModel.gatherBundle == nil ? .neutral : .good)
            ),
            WorkflowStep(
                id: "prompt",
                title: "4. Strong Prompt",
                detail: viewModel.gatherBundle == nil ? "Copy when ready." : "Ready for another model.",
                tone: viewModel.gatherBundle == nil ? .neutral : .good
            ),
        ]
    }

    private func strongPromptPanel(_ bundle: GatherBundle) -> some View {
        let packet = bundle.codex_packet ?? bundle.enriched_prompt ?? ""
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Strong Prompt Ready", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                    .foregroundColor(.green)
                Spacer()
                if let quality = bundle.audit?.evidence_quality?.status ?? bundle.audit?.missing_evidence?.status {
                    StatusChip(text: quality, tone: quality == "ok" ? .good : .warning)
                }
                if let tokens = bundle.estimated_tokens {
                    StatusChip(text: "~\(tokens) tokens", tone: .neutral)
                }
                Button {
                    copyToClipboard(packet)
                } label: {
                    Label("Copy Prompt", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(packet.isEmpty)
            }

            if let summary = bundle.context_summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(packet.isEmpty ? "No prompt text was returned." : packet)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(42)
                .padding(10)
                .background(Color(NSColor.textBackgroundColor).opacity(0.80))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
        .background(Color.green.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.20)))
    }

    @ViewBuilder
    private func warningsPanel(_ bundle: GatherBundle) -> some View {
        let warnings = evidenceWarnings(bundle)
        if !warnings.isEmpty {
            StatusBanner(
                title: "Check these before using the prompt",
                detail: warnings.prefix(5).joined(separator: "\n"),
                tone: .warning
            )
        }
    }

    private func evidencePanel(_ bundle: GatherBundle) -> some View {
        DetailDisclosure(
            title: "Evidence Package",
            subtitle: "\(bundle.evidence_items?.count ?? 0) selected items and quality signals",
            icon: "tray.full",
            isExpanded: $showEvidence
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if let mode = bundle.packet_mode {
                        StatusChip(text: mode, tone: .info)
                    }
                    StatusChip(text: "analyst", tone: .neutral)
                    if let confidence = bundle.confidence {
                        StatusChip(text: String(format: "confidence %.2f", confidence), tone: confidence >= 0.65 ? .good : .warning)
                    }
                    if let graphStatus = graphifyStatus(bundle) {
                        StatusChip(text: graphStatus.components(separatedBy: "\n").first ?? "graphify", tone: .neutral)
                    }
                }

                if let evidence = bundle.evidence_items, !evidence.isEmpty {
                    ForEach(Array(evidence.enumerated()), id: \.offset) { _, item in
                        EvidenceRow(item: item)
                    }
                } else {
                    Text("No evidence items were returned.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func planPanel(_ bundle: GatherBundle) -> some View {
        DetailDisclosure(
            title: "Collection Plan & Diagnostics",
            subtitle: "Why this context was selected, plus git, graph, and analysis details",
            icon: "list.bullet.rectangle",
            isExpanded: $showPlan
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if let reason = bundle.gather_reason {
                    labeledBlock(title: "Why Soma Gathered Context", text: reason)
                }
                if let root = bundle.project_root {
                    labeledBlock(title: "Project Root", text: root)
                }
                if let graphStatus = graphifyStatus(bundle) {
                    labeledBlock(title: "Graphify", text: graphStatus)
                }
                if let plan = bundle.collection_plan {
                    collectionPlanBlock(plan, source: bundle.collection_plan_source)
                }
                if let gitStatus = bundle.git_status, !gitStatus.isEmpty {
                    labeledBlock(title: "Git Status", text: gitStatus)
                }
                if let diff = bundle.git_diff_summary {
                    labeledBlock(title: "Git Diff Summary", text: diffSummary(diff))
                }
                if let stages = bundle.analysis_stages, !stages.isEmpty {
                    labeledList(title: "Analysis Stages", items: stages.map(stageSummary))
                }
                if let errors = bundle.error_lines, !errors.isEmpty {
                    labeledList(title: "Normalized Errors", items: Array(errors.prefix(8)), monospaced: true, tone: .danger)
                }
            }
        }
    }

    private func evidenceWarnings(_ bundle: GatherBundle) -> [String] {
        var warnings: [String] = []
        if let quality = bundle.audit?.evidence_quality {
            if quality.status == "degraded" {
                warnings.append("Evidence quality is degraded.")
            }
            warnings.append(contentsOf: quality.warnings ?? [])
        }
        if let missing = bundle.audit?.missing_evidence {
            warnings.append(contentsOf: missing.quality_warnings ?? [])
            warnings.append(contentsOf: (missing.unresolved_references ?? []).compactMap { reference in
                guard let value = reference.reference else { return nil }
                return "Unresolved \(reference.kind ?? "reference"): \(value)"
            })
            warnings.append(contentsOf: missing.requested_extra_context ?? [])
        }
        warnings.append(contentsOf: bundle.estimated_context_reduction?.warnings ?? [])
        warnings.append(contentsOf: bundle.collection_plan_warnings ?? [])
        warnings.append(contentsOf: bundle.collection_plan?.warnings ?? [])
        if let quality = bundle.evidence_quality {
            if let missing = quality["missing_required_evidence"]?.value as? [AnyCodable] {
                warnings.append(contentsOf: missing.map { "Missing required evidence: \($0.displayValue)" })
            }
            if let excluded = quality["excluded_context_selected"]?.value as? [AnyCodable] {
                warnings.append(contentsOf: excluded.map { "Excluded context selected: \($0.displayValue)" })
            }
            if let planStatus = quality["plan_alignment_status"]?.displayValue, planStatus == "degraded" {
                warnings.append("Evidence does not fully match the collection plan.")
            }
        }
        warnings.append(contentsOf: graphifyWarnings(bundle))
        return Array(NSOrderedSet(array: warnings)) as? [String] ?? warnings
    }

    private func graphifyStatus(_ bundle: GatherBundle) -> String? {
        guard let omitted = bundle.omitted_context else { return nil }
        guard let status = omitted["graphify"]?.displayValue else { return nil }
        var lines = ["Status: \(status)"]
        if let answers = omitted["graph_answers"]?.displayValue {
            lines.append("Answers: \(answers)")
        }
        lines.append(contentsOf: graphifyWarnings(bundle).map { "Warning: \($0)" })
        return lines.joined(separator: "\n")
    }

    private func graphifyWarnings(_ bundle: GatherBundle) -> [String] {
        guard let warningValue = bundle.omitted_context?["graph_warnings"] else { return [] }
        if let warnings = warningValue.value as? [AnyCodable] {
            return warnings.map { $0.displayValue }.filter { !$0.isEmpty }
        }
        let text = warningValue.displayValue
        return text.isEmpty ? [] : [text]
    }

    private func diffSummary(_ summary: GitDiffSummary) -> String {
        var lines = ["Changed files: \(summary.changed_file_count ?? summary.changed_files?.count ?? 0)"]
        if let omitted = summary.raw_diff_chars_omitted {
            lines.append("Raw diff omitted: \(omitted) chars")
        }
        if let files = summary.changed_files, !files.isEmpty {
            lines.append(contentsOf: files.prefix(8).map { "- \($0.status ?? "?") \($0.path ?? "")" })
        }
        return lines.joined(separator: "\n")
    }

    private func stageSummary(_ stage: AnalysisStage) -> String {
        var parts = [stage.stage ?? "stage", stage.status ?? "unknown"]
        if let model = stage.model { parts.append(model) }
        if let error = stage.error, !error.isEmpty { parts.append("error: \(error)") }
        if let notes = stage.notes, !notes.isEmpty { parts.append(notes.prefix(2).joined(separator: "; ")) }
        return parts.joined(separator: " | ")
    }

    private func collectionPlanBlock(_ plan: CollectionPlan, source: String?) -> some View {
        var lines: [String] = []
        if let source { lines.append("Source: \(source)") }
        if let task = plan.task_type { lines.append("Task type: \(task)") }
        if let scope = plan.target_scope { lines.append("Target scope: \(scope)") }
        if let hints = plan.scope_hints, !hints.isEmpty {
            lines.append("Scope hints: \(hints.prefix(5).joined(separator: ", "))")
        }
        if let required = plan.required_evidence, !required.isEmpty {
            lines.append("Required: \(required.prefix(8).joined(separator: ", "))")
        }
        if let excluded = plan.excluded_context, !excluded.isEmpty {
            lines.append("Excluded: \(excluded.prefix(6).joined(separator: ", "))")
        }
        if let confidence = plan.confidence {
            lines.append(String(format: "Planner confidence: %.2f", confidence))
        }
        return labeledBlock(title: "Collection Plan", text: lines.joined(separator: "\n"))
    }

    private func labeledBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.bold())
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labeledList(title: String, items: [String], monospaced: Bool = false, tone: SomaStatusTone = .neutral) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.bold())
            ForEach(items, id: \.self) { item in
                Text("- \(item)")
                    .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                    .foregroundColor(tone == .danger ? .red : .secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

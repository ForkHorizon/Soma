import SwiftUI

struct LogsView: View {
    @ObservedObject var viewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager
    @State private var eventFilter = "all"
    @State private var statusFilter = "all"
    @State private var clientFilter = "all"
    @State private var traceFilter = ""
    @State private var selectedLogID: SomaLogEntry.ID?
    @State private var pendingDeleteAction: DeleteAction?
    @State private var deletionFeedback: String?

    private enum DeleteAction: Identifiable {
        case clearVisible(count: Int)
        case deleteRun(String)
        case deleteToday(count: Int)
        case deleteAll
        case resetAuditTraces
        case startNewSession

        var id: String { title }

        var title: String {
            switch self {
            case .clearVisible: return "Clear Visible"
            case .deleteRun: return "Delete Run"
            case .deleteToday: return "Delete Today"
            case .deleteAll: return "Delete All Logs"
            case .resetAuditTraces: return "Reset Audit Traces"
            case .startNewSession: return "Start New Session"
            }
        }

        var message: String {
            switch self {
            case .clearVisible(let count): return "Delete \(count) currently visible filtered activity entries from today's log file."
            case .deleteRun(let runID): return "Delete all entries for run \(runID) from today's log file."
            case .deleteToday(let count):
                return "Delete today's loaded log file and remove \(count) visible activity entries. Audit traces are not deleted."
            case .deleteAll:
                return "Delete all Soma logs, analytics, and token stats. Audit traces are kept separate unless you reset them explicitly."
            case .resetAuditTraces: return "Delete Soma audit trace files separately from activity logs."
            case .startNewSession: return "Start a clean visible activity session and reset session stats without deleting audit traces."
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            logsHeader
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(Color(NSColor.windowBackgroundColor))
                .overlay(Divider(), alignment: .bottom)

            if filteredLogEntries.isEmpty && !viewModel.logsLoading {
                emptyState
            } else {
                activityLayout
            }
        }
        .background(SomaDesign.pageBackground)
        .confirmationDialog(
            pendingDeleteAction?.title ?? "Confirm Deletion",
            isPresented: Binding(
                get: { pendingDeleteAction != nil },
                set: { if !$0 { pendingDeleteAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = pendingDeleteAction {
                Button(action.title, role: .destructive) {
                    performDelete(action)
                    pendingDeleteAction = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteAction = nil
            }
        } message: {
            Text(pendingDeleteAction?.message ?? "Choose an explicit deletion scope.")
        }
        .onAppear {
            viewModel.loadStructuredLogs()
            viewModel.loadAuditReport()
        }
    }

    // MARK: - Empty state

    private var activityLayout: some View {
        GeometryReader { proxy in
            if proxy.size.width < 1180 {
                VStack(spacing: 0) {
                    HSplitView {
                        activitySummaryPanel
                            .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)

                        logEntryList
                            .frame(minWidth: 360)
                    }
                    Divider()
                    activityDetailInspector
                        .frame(minHeight: 220, idealHeight: 260, maxHeight: 320)
                }
            } else {
                HSplitView {
                    activitySummaryPanel
                        .frame(minWidth: 260, idealWidth: 310, maxWidth: 340)

                    logEntryList
                        .frame(minWidth: 420)

                    activityDetailInspector
                        .frame(minWidth: 280, idealWidth: 340, maxWidth: 400)
                }
            }
        }
    }

    private var logsHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Activity")
                        .font(.title2.bold())
                        .lineLimit(1)
                    Text(logsSubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button {
                        viewModel.loadStructuredLogs()
                        viewModel.loadAuditReport()
                    } label: {
                        if viewModel.logsLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.logsLoading || viewModel.logsClearBusy)
                    .help("Reload today's structured logs and latest audit report.")

                    Menu {
                        Button("Clear Visible") {
                            pendingDeleteAction = .clearVisible(count: filteredLogEntries.count)
                        }
                        .disabled(filteredLogEntries.isEmpty)

                        if let runID = selectedEntry?.run_id {
                            Button("Delete Run") {
                                pendingDeleteAction = .deleteRun(runID)
                            }
                        }

                        Button("Delete Today") {
                            pendingDeleteAction = .deleteToday(count: viewModel.logEntries.count)
                        }
                        .disabled(viewModel.logEntries.isEmpty)

                        Divider()

                        Button("Reset Audit Traces") {
                            pendingDeleteAction = .resetAuditTraces
                        }
                        .disabled(viewModel.auditReport == nil)

                        Button("Start New Session") {
                            pendingDeleteAction = .startNewSession
                        }

                        Divider()

                        Button("Delete All Logs") {
                            pendingDeleteAction = .deleteAll
                        }
                        .disabled(viewModel.logEntries.isEmpty && viewModel.toolStats.isEmpty && viewModel.localModelStats.isEmpty)
                    } label: {
                        if viewModel.logsClearBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Delete Scope", systemImage: "trash")
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .tint(.red)
                    .disabled(viewModel.logsLoading || viewModel.logsClearBusy)
                    .help("Choose an explicit activity, log, or audit deletion scope. Soma never uses an ambiguous Clear action here.")
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    filterPicker("Event", selection: $eventFilter, allTitle: "All Events", options: eventOptions, width: 150)
                    filterPicker("Status", selection: $statusFilter, allTitle: "All Status", options: statusOptions, width: 140)
                    filterPicker("Client", selection: $clientFilter, allTitle: "All Clients", options: clientOptions, width: 140)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Run or task")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                        TextField("Filter by run/task", text: $traceFilter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                    }
                }
                .padding(.bottom, 1)
            }
        }
    }

    private func filterPicker(_ title: String, selection: Binding<String>, allTitle: String, options: [String], width: CGFloat) -> some View
    {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
            Picker(title, selection: selection) {
                Text(allTitle).tag("all")
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: width)
        }
    }

    private var filteredLogEntries: [SomaLogEntry] {
        viewModel.logEntries.filter { entry in
            (eventFilter == "all" || entry.event == eventFilter)
                && (statusFilter == "all" || entry.status == statusFilter)
                && (clientFilter == "all" || entry.client == clientFilter)
                && traceMatches(entry)
        }
    }

    private var logsSubtitle: String {
        let total = viewModel.logEntries.count
        let shown = filteredLogEntries.count
        if total == 0 {
            return "No entries loaded from \(logFilePath)"
        }
        if shown == total {
            return "Showing \(shown) entries from \(logFilePath)"
        }
        return "Showing \(shown) of \(total) entries from \(logFilePath)"
    }

    private func traceMatches(_ entry: SomaLogEntry) -> Bool {
        let filter = traceFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !filter.isEmpty else { return true }
        return (entry.run_id?.lowercased().contains(filter) == true)
            || (entry.task_id?.lowercased().contains(filter) == true)
            || (entry.workflow?.lowercased().contains(filter) == true)
    }

    private var eventOptions: [String] {
        Array(Set(viewModel.logEntries.map(\.event))).sorted()
    }

    private var statusOptions: [String] {
        Array(Set(viewModel.logEntries.map(\.status))).sorted()
    }

    private var clientOptions: [String] {
        Array(Set(viewModel.logEntries.compactMap(\.client))).sorted()
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(emptyStateTitle)
                .font(.title3)
            Text(emptyStateDetail)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var activityOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Summary")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Spacer()
                Text("Today")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            let packetRuns = Set(
                viewModel.logEntries.filter { $0.event.contains("packet") || $0.workflow?.contains("packet") == true }.compactMap {
                    $0.run_id ?? $0.task_id
                }
            ).count
            let warnings = viewModel.logEntries.filter { $0.isError || $0.isDegraded || $0.error != nil }.count

            HStack(spacing: 10) {
                statBadge(value: "\(viewModel.logEntries.count)", label: "Events", color: .blue)
                statBadge(value: "\(packetRuns)", label: "Packet Runs", color: .purple)
                statBadge(value: "\(warnings)", label: "Warnings", color: warnings > 0 ? .orange : .green)
            }

            if let deletionFeedback {
                Label(deletionFeedback, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundColor(.green)
                    .lineLimit(2)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Recent Timeline")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                ForEach(filteredLogEntries.prefix(4)) { entry in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor(entry))
                            .frame(width: 6, height: 6)
                        Text(entry.shortTime.suffix(5))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text(activitySummary(for: entry))
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selectedLogID = entry.id }
                }
                if filteredLogEntries.isEmpty {
                    Text(emptyStateTitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(SomaDesign.panelBackground)
    }

    private var activitySummaryPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            activityOverview
            Divider()
            Text("Tool Stats Today")
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()

            // Summary row
            let totalCalls = viewModel.toolStats.reduce(0) { $0 + $1.calls }
            let totalTok = viewModel.toolStats.reduce(0) { $0 + $1.totalTokens }
            let totalSaved = viewModel.toolStats.reduce(0) { $0 + max($1.totalOperationSavedTokens, $1.totalSavedTokens) }
            let totalErr = viewModel.toolStats.reduce(0) { $0 + $1.errors }
            let localCalls = viewModel.localModelStats.reduce(0) { $0 + $1.calls }

            HStack(spacing: 12) {
                statBadge(value: "\(totalCalls)", label: "Calls", color: .blue)
                statBadge(value: "\(totalTok)", label: "Tokens", color: .purple)
                if totalSaved > 0 {
                    statBadge(value: "\(totalSaved)", label: "Op Saved", color: .green)
                }
                if totalErr > 0 {
                    statBadge(value: "\(totalErr)", label: "Errors", color: .red)
                }
                if localCalls > 0 {
                    statBadge(value: "\(localCalls)", label: "Local AI", color: .teal)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()
            taskTracePanel
            Divider()
            localModelPanel
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.toolStats) { stat in
                        toolStatRow(stat)
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
        .background(SomaDesign.panelBackground)
    }

    private var taskTracePanel: some View {
        let audit = viewModel.auditReport
        let unresolved = (audit?.missing_evidence?.missing_files?.count ?? 0) + (audit?.missing_evidence?.missing_symbols?.count ?? 0)
        let concepts = audit?.missing_evidence?.unresolved_concepts?.count ?? 0
        let notSelected = audit?.missing_evidence?.found_not_selected?.count ?? 0

        return VStack(alignment: .leading, spacing: 6) {
            Text("Latest Task Trace")
                .font(.caption.bold())
                .foregroundColor(.secondary)
            if let audit {
                Text(audit.run_id ?? "unknown run")
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    traceChip(audit.status ?? "unknown", color: audit.status == "ok" ? .green : (audit.status == "failed" ? .red : .orange))
                    traceChip("\(audit.selected_evidence?.count ?? 0) evidence", color: .blue)
                    if unresolved + notSelected > 0 {
                        traceChip("\(unresolved + notSelected) missing", color: .orange)
                    }
                    if concepts > 0 {
                        traceChip("\(concepts) concepts", color: .secondary)
                    }
                }
                if let missing = (audit.missing_evidence?.missing_files?.first ?? audit.missing_evidence?.missing_symbols?.first)?.reference
                {
                    Text("Missing: \(missing)")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }
                if let review = audit.quality_review?.status {
                    Text("Quality: \(review.replacingOccurrences(of: "_", with: " "))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("No audit report yet")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func traceChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .cornerRadius(4)
    }

    private var localModelPanel: some View {
        let calls = viewModel.localModelStats.reduce(0) { $0 + $1.calls }
        let tokens = viewModel.localModelStats.reduce(0) { $0 + $1.totalTokens }
        let errors = viewModel.localModelStats.reduce(0) { $0 + $1.errors }

        return VStack(alignment: .leading, spacing: 6) {
            Text("Local Model Today")
                .font(.caption.bold())
                .foregroundColor(.secondary)
            Text("Configured: Scout \(ollama.modelName), Ranker \(ollama.rankerModelName), Analyst \(ollama.analystModelName)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(2)
            if calls == 0 {
                Text("No Ollama calls logged")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 6) {
                    traceChip("\(calls) calls", color: .teal)
                    traceChip("\(tokens) tok", color: .purple)
                    if errors > 0 {
                        traceChip("\(errors) err", color: .red)
                    }
                }
                ForEach(viewModel.localModelStats.prefix(3)) { stat in
                    Text(
                        "\(stat.id): \(roleSummary(model: stat.id, stages: stat.stages)) · \(stat.calls) calls · \(Int(stat.avgDuration))ms avg · \(stageSummary(stat.stages))"
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func statBadge(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(.callout, design: .monospaced).bold())
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(minWidth: 48)
    }

    private func toolStatRow(_ stat: SomaToolStat) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.id)
                    .font(.caption.bold())
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(stat.calls) calls")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    if stat.avgDuration > 0 {
                        Text("\(Int(stat.avgDuration))ms avg")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if let savings = stat.avgOperationSavingsPct ?? stat.avgSavingsPct {
                        Text(String(format: "%.1f%% ops", savings))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.green)
                    }
                }
            }
            Spacer()
            if stat.errors > 0 {
                Text("\(stat.errors) err")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.red)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Log entry list

    private var logEntryList: some View {
        List(filteredLogEntries) { entry in
            logRow(entry)
                .contentShape(Rectangle())
                .onTapGesture { selectedLogID = entry.id }
                .listRowBackground(selectedLogID == entry.id ? Color.accentColor.opacity(0.12) : Color.clear)
                .listRowSeparator(.visible)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        }
        .listStyle(.plain)
    }

    private func logRow(_ entry: SomaLogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Status dot
            Circle()
                .fill(statusColor(entry))
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.displayName)
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundColor(entry.isError ? .red : .primary)
                    Spacer()
                    Text(entry.shortTime)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Text(logMetadata(entry).joined(separator: " · "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(entry.isError ? .red : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if entry.event == "local_model_call" {
                    Text(
                        [
                            entry.local_model_provider,
                            entry.local_model,
                            entry.local_model_json_mode == true ? "json" : nil,
                            entry.local_model_num_predict.map { "predict \($0)" },
                        ].compactMap { $0 }.joined(separator: " · ")
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
                if entry.baseline_type != nil || entry.token_estimator != nil {
                    Text([entry.baseline_type, entry.token_estimator].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                if let saved = entry.prompt_saved_tokens, saved > 0 {
                    Text(String(format: "prompt language optimization saved %d tokens (%.1f%%)", saved, entry.prompt_savings_pct ?? 0))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                if let estimated = entry.estimated_context_reduction_pct {
                    Text(String(format: "estimated context reduction %.1f%%", estimated))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                if let calls = entry.local_ai_call_count, calls > 0 {
                    Text(
                        "local AI used: \(calls) calls, \((entry.local_ai_input_tokens ?? 0) + (entry.local_ai_output_tokens ?? 0)) tok, saved \(entry.local_ai_net_savings_tokens ?? 0) candidate tok"
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
                if let omitted = entry.omitted_output_tokens, omitted > 0 {
                    Text("large output compacted, omitted \(omitted) tok")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
                if let err = entry.error {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail inspector

    private var activityDetailInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Detail Inspector")
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()

            if let entry = selectedEntry ?? filteredLogEntries.first {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(activitySummary(for: entry))
                                    .font(.headline)
                                    .lineLimit(2)
                                Text(entry.shortTime)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            traceChip(entry.status, color: statusColor(entry))
                        }

                        detailSection("Request") {
                            detailRow("Source / client", entry.client ?? "Soma")
                            detailRow("Request type", entry.event)
                            detailRow("Tool / method", entry.tool ?? entry.method ?? "—")
                            detailRow(
                                "Project / workspace",
                                viewModel.selectedProjectRoot.isEmpty ? "No project selected" : viewModel.selectedProjectRoot)
                            detailRow("Input summary", inputSummary(for: entry))
                        }

                        detailSection("Model, tools, and stages") {
                            detailRow("Provider", entry.local_model_provider ?? "—")
                            detailRow("Model / role", modelSummary(for: entry))
                            detailRow("Workflow", entry.workflow ?? "—")
                            detailRow("Stage", entry.local_model_stage ?? "—")
                            detailRow("Tools used", toolsSummary(for: entry))
                        }

                        detailSection("Data and result") {
                            detailRow("Tokens", tokenSummary(for: entry))
                            detailRow("Duration", entry.duration_ms.map { "\(Int($0))ms" } ?? "—")
                            detailRow("Status", entry.status)
                            detailRow("Warnings / errors", entry.error ?? warningSummary(for: entry))
                            detailRow("Output", outputSummary(for: entry))
                        }

                        detailSection("Audit") {
                            detailRow("Run ID", entry.run_id ?? viewModel.auditReport?.run_id ?? "—")
                            detailRow("Task ID", entry.task_id ?? "—")
                            detailRow("Packet hash", entry.packet_hash ?? "—")
                            detailRow("Prompt hash", entry.prompt_hash ?? "—")
                            detailRow("Related files", relatedFilesSummary)
                        }

                        DisclosureGroup("Raw Logs") {
                            Text(entry.rawPayload ?? "Raw payload unavailable for this entry.")
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color.secondary.opacity(0.08))
                                .cornerRadius(8)
                        }
                        .font(.caption.weight(.semibold))
                    }
                    .padding(12)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "sidebar.right")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Select an activity row")
                        .font(.headline)
                    Text(
                        "Details show source, request type, project, model, data volume, status, audit IDs, related files, and raw payload when needed."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(SomaDesign.panelBackground)
    }

    @ViewBuilder
    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 10, design: label.contains("ID") || label.contains("hash") ? .monospaced : .default))
                .textSelection(.enabled)
                .lineLimit(4)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Helpers

    private var selectedEntry: SomaLogEntry? {
        guard let selectedLogID else { return nil }
        return viewModel.logEntries.first { $0.id == selectedLogID }
    }

    private var emptyStateTitle: String {
        if viewModel.logEntries.isEmpty { return "No logs for today" }
        if eventFilter != "all" || statusFilter != "all" || clientFilter != "all"
            || !traceFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return "No logs match current filters"
        }
        if !viewModel.selectedProjectRoot.isEmpty { return "No activity for this project" }
        return "No activity to show"
    }

    private var emptyStateDetail: String {
        if viewModel.logEntries.isEmpty {
            return deletionFeedback
                ?? "Run Prepare Packet, use an MCP client, or refresh after a tool call. Logs are saved to \(logFilePath)."
        }
        return "Adjust Event, Status, Client, or Run filters to widen the current Activity scope."
    }

    private var relatedFilesSummary: String {
        let files = viewModel.auditReport?.selected_evidence?.compactMap(\.path) ?? []
        if files.isEmpty { return "—" }
        return files.prefix(4).joined(separator: ", ") + (files.count > 4 ? " +\(files.count - 4) more" : "")
    }

    private func activitySummary(for entry: SomaLogEntry) -> String {
        if entry.event == "local_model_call" {
            return entry.isError ? "Local model call failed" : "Local model call completed"
        }
        if entry.displayName.lowercased().contains("prepare") || entry.workflow?.lowercased().contains("packet") == true {
            return entry.isError ? "Prepare Packet failed" : "Prepare Packet completed"
        }
        if let client = entry.client, let method = entry.method ?? entry.tool {
            return "\(client) requested \(method)"
        }
        return entry.displayName.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func inputSummary(for entry: SomaLogEntry) -> String {
        var parts: [String] = []
        if let baseline = entry.baseline_type { parts.append(baseline) }
        if let budget = entry.budget_used_pct { parts.append(String(format: "%.1f%% budget", budget)) }
        if let messages = entry.local_model_message_count { parts.append("\(messages) messages") }
        if let tools = entry.local_model_tool_count { parts.append("\(tools) tools") }
        return parts.isEmpty ? "See raw logs for full payload" : parts.joined(separator: " · ")
    }

    private func modelSummary(for entry: SomaLogEntry) -> String {
        guard let model = entry.local_model else { return "—" }
        if let role = ollama.configuredRole(for: model, stage: entry.local_model_stage) {
            return "\(model) · \(role.title)"
        }
        return model
    }

    private func toolsSummary(for entry: SomaLogEntry) -> String {
        if let count = entry.local_model_tool_count { return "\(count) advertised tools" }
        return entry.tool ?? entry.method ?? "—"
    }

    private func tokenSummary(for entry: SomaLogEntry) -> String {
        var parts: [String] = []
        if let input = entry.input_tokens { parts.append("in \(input)") }
        if let output = entry.output_tokens { parts.append("out \(output)") }
        if let packet = entry.packet_tokens { parts.append("packet \(packet)") }
        if let saved = entry.operation_saved_tokens ?? entry.saved_tokens, saved > 0 { parts.append("saved \(saved)") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func warningSummary(for entry: SomaLogEntry) -> String {
        if entry.isDegraded { return "Degraded evidence or partial result" }
        if entry.output_truncated == true { return "Large output compacted" }
        return "None"
    }

    private func outputSummary(for entry: SomaLogEntry) -> String {
        if let omitted = entry.omitted_output_tokens, omitted > 0 { return "Compacted; omitted \(omitted) tokens" }
        if let response = entry.soma_response_tokens { return "Soma response \(response) tokens" }
        return entry.output_tokens.map { "\($0) output tokens" } ?? "—"
    }

    private func performDelete(_ action: DeleteAction) {
        switch action {
        case .clearVisible:
            let entries = filteredLogEntries
            viewModel.deleteVisibleLogs(entries)
            deletionFeedback = "Cleared visible logs"
        case .deleteRun(let runID):
            viewModel.deleteRunLogs(runID: runID)
            deletionFeedback = "Run deleted"
        case .deleteToday:
            viewModel.deleteTodayLogs()
            deletionFeedback = "Deleted today's logs"
        case .deleteAll:
            viewModel.clearAllLogs()
            deletionFeedback = "Deleted all logs"
        case .resetAuditTraces:
            viewModel.resetAuditTraces()
            deletionFeedback = "Reset audit traces"
        case .startNewSession:
            viewModel.startNewLogSession()
            deletionFeedback = "Started new clean session"
        }
        selectedLogID = nil
        eventFilter = "all"
        statusFilter = "all"
        clientFilter = "all"
        traceFilter = ""
    }

    private func statusColor(_ entry: SomaLogEntry) -> Color {
        if entry.isError { return .red }
        if entry.isDegraded { return .orange }
        if entry.status == "skipped" { return .secondary }
        return .green
    }

    private var logFilePath: String {
        let dateStr = DateFormatter.somaDate.string(from: Date())
        return "~/.soma/logs/soma_\(dateStr).jsonl"
    }

    private func stageSummary(_ stages: [String: Int]) -> String {
        stages
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { "\($0.key) \($0.value)" }
            .joined(separator: ", ")
    }

    private func roleSummary(model: String, stages: [String: Int]) -> String {
        let topStage = stages.sorted { $0.value > $1.value }.first?.key
        return ollama.configuredRole(for: model, stage: topStage)?.title ?? "unmapped"
    }

    private func logMetadata(_ entry: SomaLogEntry) -> [String] {
        var parts = [entry.event]
        if let client = entry.client {
            parts.append(client)
        }
        if let runID = entry.run_id {
            parts.append(String(runID.prefix(12)))
        }
        if let taskID = entry.task_id {
            parts.append(taskID)
        }
        if let dur = entry.duration_ms, dur > 0 {
            parts.append("\(Int(dur))ms")
        }
        if entry.totalTokens > 0 {
            parts.append("\(entry.totalTokens) tok")
        }
        if let budgetUsed = entry.budget_used_pct {
            parts.append(String(format: "%.1f%% budget", budgetUsed))
        }
        if let savings = entry.operation_savings_pct ?? entry.savings_pct {
            parts.append(String(format: "%.1f%% ops", savings))
        }
        if let saved = entry.operation_saved_tokens ?? entry.saved_tokens, saved > 0 {
            parts.append("\(saved) saved")
        }
        if let lang = entry.source_language, let status = entry.translation_status {
            parts.append("\(lang)->EN \(status)")
        }
        if let stage = entry.local_model_stage {
            parts.append("local \(stage)")
        }
        if let model = entry.local_model, let role = ollama.configuredRole(for: model, stage: entry.local_model_stage) {
            parts.append(role.title)
        }
        if entry.output_truncated == true {
            parts.append("compacted")
        }
        return parts
    }
}

import SwiftUI
import Foundation

struct RusToPromptScoredPreset: Identifiable {
    let preset: RusToPromptModelPreset
    let stats: TestModelRoleStats?
    var id: String { preset.model }
}

extension RusToPromptView {
    var modelPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Models")
                    .font(.headline)
                Spacer()
                StatusChip(text: modelStatsPopoverStatus, tone: modelStats == nil ? .neutral : .info)
                StatusChip(text: ollama.isOllamaRunning ? "Ollama online" : "Ollama offline", tone: ollama.isOllamaRunning ? .good : .warning)
            }

            HStack(alignment: .top, spacing: 14) {
                presetSection(
                    title: "Translator",
                    selection: Binding(
                        get: { viewModel.translatorModel },
                        set: { viewModel.translatorModel = $0 }
                    ),
                    presets: RusToPromptViewModel.translatorPresets,
                    role: .translator
                )

                Divider()
                    .frame(height: 310)

                presetSection(
                    title: "Analyzer",
                    selection: Binding(
                        get: { viewModel.analyzerModel },
                        set: { viewModel.analyzerModel = $0 }
                    ),
                    presets: RusToPromptViewModel.analyzerPresets,
                    role: .improver,
                    requiresOllama: true
                )

                Divider()
                    .frame(height: 310)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Run confidence", isOn: $viewModel.confidenceEnabled)
                        .font(.subheadline.bold())
                    presetSection(
                        title: "Confidence",
                        selection: Binding(
                            get: { viewModel.confidenceModel },
                            set: { viewModel.confidenceModel = $0 }
                        ),
                        presets: RusToPromptViewModel.confidencePresets,
                        requiresOllama: false
                    )
                }
            }
        }
        .padding(14)
        .frame(width: 1180)
    }


    func presetSection(title: String, selection: Binding<String>, presets: [RusToPromptModelPreset], role: TestModelRole? = nil, requiresOllama: Bool = true) -> some View {
        let rows = rusToPromptScoredPresets(presets: presets, role: role, selectedModel: selection.wrappedValue)
        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.bold())
            ScrollView {
                VStack(spacing: 7) {
                    ForEach(rows) { row in
                        presetRow(row, selection: selection, requiresOllama: requiresOllama)
                    }
                }
            }
            .frame(maxHeight: role == nil ? 330 : 430)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }


    func presetRow(_ row: RusToPromptScoredPreset, selection: Binding<String>, requiresOllama: Bool) -> some View {
        let preset = row.preset
        let selected = selection.wrappedValue == preset.model
        let usesCodex = preset.isCodex
        let usesGemini = preset.isGemini
        let installed = usesCodex || usesGemini || !requiresOllama || isInstalled(preset.model)

        return Button {
            selection.wrappedValue = preset.model
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selected ? .accentColor : .secondary)
                    Text(preset.model)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if preset.recommended {
                        StatusChip(text: "Recommended", tone: .good)
                    }
                    if !installed {
                        StatusChip(text: "Missing", tone: .warning)
                    } else if usesGemini {
                        StatusChip(text: "Gemini", tone: .info)
                    } else if usesCodex || !requiresOllama {
                        StatusChip(text: "Codex", tone: .info)
                    }
                    if let decision = rusToPromptScopeDecisionChip(row.stats) {
                        StatusChip(text: decision.text, tone: decision.tone)
                    }
                }

                HStack(spacing: 6) {
                    StatusChip(text: "Score \(formatModelScore(row.stats?.qualityScore))", tone: modelScoreTone(row.stats))
                    StatusChip(text: "Speed \(preset.speed)", tone: speedTone(preset.speed))
                    StatusChip(text: preset.ram, tone: .neutral)
                }
                rusToPromptScopeSummary(row.stats)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.12) : Color(NSColor.textBackgroundColor).opacity(0.64))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(rusToPromptModelHelp(preset: preset, stats: row.stats))
    }


    var modelStatsPopoverStatus: String {
        if isLoadingModelStats { return "Loading stats" }
        guard let modelStats else { return "No scores" }
        return "\(modelStats.translationModels.count + modelStats.improverModels.count) scored"
    }


    func rusToPromptScoredPresets(
        presets: [RusToPromptModelPreset],
        role: TestModelRole?,
        selectedModel: String
    ) -> [RusToPromptScoredPreset] {
        let statsRows = rusToPromptStatsRows(for: role)
        let statsByModel = rusToPromptStatsLookup(statsRows)
        var rowsByModel: [String: RusToPromptModelPreset] = [:]

        for preset in presets {
            rowsByModel[preset.model.lowercased()] = preset
        }
        if role != nil {
            for installed in ollama.installedModels {
                let key = installed.name.lowercased()
                if rowsByModel[key] == nil {
                    rowsByModel[key] = RusToPromptModelPreset(
                        model: installed.name,
                        quality: "Unknown",
                        speed: "Unknown",
                        ram: installed.formattedSize.isEmpty ? installed.parameterSize : installed.formattedSize,
                        detail: installed.displayDetail.isEmpty ? "Installed Ollama model." : installed.displayDetail,
                        recommended: false
                    )
                }
            }
            for stats in statsRows where rowsByModel[stats.model.lowercased()] == nil {
                rowsByModel[stats.model.lowercased()] = statsBackedPreset(stats)
            }
        }
        if !selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           rowsByModel[selectedModel.lowercased()] == nil {
            rowsByModel[selectedModel.lowercased()] = RusToPromptModelPreset(
                model: selectedModel,
                quality: "Unknown",
                speed: "Unknown",
                ram: "Custom",
                detail: "Selected custom model.",
                recommended: false
            )
        }

        let rows = rowsByModel.values.map { preset in
            RusToPromptScoredPreset(preset: preset, stats: statsByModel[preset.model.lowercased()])
        }
        return rows.sorted { compareRusToPromptScoredPreset($0, $1, selectedModel: selectedModel) }
    }


    func statsBackedPreset(_ stats: TestModelRoleStats) -> RusToPromptModelPreset {
        let isCodex = stats.provider == "Codex"
        let isGemini = stats.provider == "Gemini"
        return RusToPromptModelPreset(
            model: stats.model,
            quality: "Benchmarked",
            speed: "Unknown",
            ram: isCodex || isGemini ? "0 GB" : "Stats",
            detail: "Model found in benchmark stats.",
            recommended: false,
            isCodex: isCodex,
            provider: isGemini ? "gemini" : nil
        )
    }


    func compareRusToPromptScoredPreset(
        _ lhs: RusToPromptScoredPreset,
        _ rhs: RusToPromptScoredPreset,
        selectedModel: String
    ) -> Bool {
        let lhsScore = lhs.stats?.qualityScore ?? -1
        let rhsScore = rhs.stats?.qualityScore ?? -1
        if lhsScore != rhsScore { return lhsScore > rhsScore }

        let lhsClean = lhs.stats.flatMap { rusToPromptCleanRate($0) } ?? -1
        let rhsClean = rhs.stats.flatMap { rusToPromptCleanRate($0) } ?? -1
        if lhsClean != rhsClean { return lhsClean > rhsClean }

        let lhsProblems = lhs.stats.map { rusToPromptProblemCount($0) } ?? Int.max
        let rhsProblems = rhs.stats.map { rusToPromptProblemCount($0) } ?? Int.max
        if lhsProblems != rhsProblems { return lhsProblems < rhsProblems }

        let lhsAttempts = lhs.stats?.attempts ?? -1
        let rhsAttempts = rhs.stats?.attempts ?? -1
        if lhsAttempts != rhsAttempts { return lhsAttempts > rhsAttempts }

        let lhsSelected = lhs.preset.model.caseInsensitiveCompare(selectedModel) == .orderedSame
        let rhsSelected = rhs.preset.model.caseInsensitiveCompare(selectedModel) == .orderedSame
        if lhsSelected != rhsSelected { return lhsSelected }

        if lhs.preset.recommended != rhs.preset.recommended { return lhs.preset.recommended }
        return lhs.preset.model.localizedStandardCompare(rhs.preset.model) == .orderedAscending
    }


    func rusToPromptStatsRows(for role: TestModelRole?) -> [TestModelRoleStats] {
        guard let modelStats, let role else { return [] }
        switch role {
        case .translator:
            return modelStats.translationModels
        case .improver:
            return modelStats.improverModels
        }
    }


    func rusToPromptStatsLookup(_ rows: [TestModelRoleStats]) -> [String: TestModelRoleStats] {
        var lookup: [String: TestModelRoleStats] = [:]
        for row in rows {
            lookup[row.model.lowercased()] = row
        }
        return lookup
    }


    @ViewBuilder
    func rusToPromptScopeSummary(_ stats: TestModelRoleStats?) -> some View {
        if let stats {
            HStack(spacing: 6) {
                Text("\(stats.attempts) runs")
                Text("clean \(formatPercent(rusToPromptCleanRate(stats) ?? 0))")
                if rusToPromptProblemCount(stats) > 0 {
                    Text("\(rusToPromptProblemCount(stats)) problems")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundColor(rusToPromptScopeSummaryColor(stats))
        } else {
            Text("No benchmark score yet")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }


    func rusToPromptScopeSummaryColor(_ stats: TestModelRoleStats) -> Color {
        let clean = rusToPromptCleanRate(stats) ?? 0
        if stats.attempts > 0 && clean == 0 { return .red }
        if rusToPromptProblemCount(stats) > 0 || clean < 0.80 { return .orange }
        return .secondary
    }


    func rusToPromptScopeDecisionChip(_ stats: TestModelRoleStats?) -> (text: String, tone: SomaStatusTone)? {
        guard let stats, stats.attempts > 0 else { return nil }
        let problemCount = rusToPromptProblemCount(stats)
        if problemCount == stats.attempts {
            return ("100% problems", .danger)
        }
        if stats.attempts < 5 {
            return ("Small sample", .warning)
        }
        let clean = rusToPromptCleanRate(stats) ?? 0
        if clean < 0.50 {
            return ("High risk", .warning)
        }
        if clean >= 0.90 && (stats.qualityScore ?? 0) >= 0.86 {
            return ("Stable", .good)
        }
        return nil
    }


    func rusToPromptModelHelp(preset: RusToPromptModelPreset, stats: TestModelRoleStats?) -> String {
        guard let stats else {
            return "\(preset.detail)\nNo benchmark score yet."
        }
        let problemRate = stats.attempts > 0 ? Double(rusToPromptProblemCount(stats)) / Double(stats.attempts) : 0
        return [
            preset.detail,
            "Scope: \(stats.attempts) runs, \(stats.confidenceCount) usable scores.",
            "Score \(formatModelScore(stats.qualityScore)); clean \(formatPercent(rusToPromptCleanRate(stats) ?? 0)); problems \(rusToPromptProblemCount(stats)) (\(formatPercent(problemRate))).",
            "Judge failed \(stats.confidenceFailedCount), run failed \(stats.pipelineFailedCount), degraded \(stats.degradedCount)."
        ]
        .joined(separator: "\n")
    }


    func rusToPromptProblemCount(_ stats: TestModelRoleStats) -> Int {
        stats.problemCount ?? stats.worstCases.filter { item in
            item.confidenceFailed == true || item.status != "ok"
        }.count
    }


    func rusToPromptCleanRate(_ stats: TestModelRoleStats) -> Double? {
        guard stats.attempts > 0 else { return nil }
        let cleanCount = max(0, stats.attempts - rusToPromptProblemCount(stats))
        return Double(cleanCount) / Double(stats.attempts)
    }


    func modelScoreTone(_ stats: TestModelRoleStats?) -> SomaStatusTone {
        guard let score = stats?.qualityScore else { return .neutral }
        if score >= 0.86 { return .good }
        if score >= 0.75 { return .info }
        if score >= 0.50 { return .warning }
        return .danger
    }


    func formatModelScore(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.2f", value)
    }


    func formatPercent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }


    var rusToPromptRepoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }


    var rusToPromptStatsScriptURL: URL {
        rusToPromptRepoRootURL
            .appendingPathComponent("Scripts")
            .appendingPathComponent("rus_to_prompt_stats.py")
    }


    var rusToPromptStressDirectoryURL: URL {
        rusToPromptRepoRootURL.appendingPathComponent(".stress")
    }


    func loadRusToPromptModelStatsIfNeeded() {
        guard modelStats == nil, !isLoadingModelStats else { return }
        loadRusToPromptModelStats()
    }


    func loadRusToPromptModelStats() {
        guard !isLoadingModelStats else { return }
        let scriptURL = rusToPromptStatsScriptURL
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            modelStatsStatus = "Stats script missing"
            return
        }

        isLoadingModelStats = true
        modelStatsStatus = "Loading stats"
        let rootURL = rusToPromptRepoRootURL
        let stressURL = rusToPromptStressDirectoryURL
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SOMA_PROJECT_ROOT")
        environment["PYTHONDONTWRITEBYTECODE"] = "1"

        DispatchQueue.global(qos: .userInitiated).async {
            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("soma-rus-to-prompt-stats-\(UUID().uuidString)", isDirectory: true)
            let stdoutURL = tempDirectory.appendingPathComponent("stdout.json")
            let stderrURL = tempDirectory.appendingPathComponent("stderr.log")
            var stdoutHandle: FileHandle?
            var stderrHandle: FileHandle?
            let process = Process()
            process.currentDirectoryURL = rootURL
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [
                scriptURL.path,
                "--stress-dir", stressURL.path
            ]
            process.environment = environment

            do {
                try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
                _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
                stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
                stderrHandle = try FileHandle(forWritingTo: stderrURL)
                process.standardOutput = stdoutHandle
                process.standardError = stderrHandle
                try process.run()
                process.waitUntilExit()
                try? stdoutHandle?.close()
                try? stderrHandle?.close()
                stdoutHandle = nil
                stderrHandle = nil
                defer { try? FileManager.default.removeItem(at: tempDirectory) }
                let data = (try? Data(contentsOf: stdoutURL)) ?? Data()
                let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
                if process.terminationStatus != 0 {
                    let detail = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    DispatchQueue.main.async {
                        self.isLoadingModelStats = false
                        self.modelStatsStatus = detail.isEmpty ? "Stats failed" : "Stats failed: \(detail)"
                    }
                    return
                }
                DispatchQueue.main.async {
                    do {
                        self.modelStats = try JSONDecoder().decode(TestModelStatsEnvelope.self, from: data)
                        self.modelStatsStatus = "Loaded scores"
                    } catch {
                        self.modelStatsStatus = "Stats failed: \(error.localizedDescription)"
                    }
                    self.isLoadingModelStats = false
                }
            } catch {
                try? stdoutHandle?.close()
                try? stderrHandle?.close()
                try? FileManager.default.removeItem(at: tempDirectory)
                DispatchQueue.main.async {
                    self.isLoadingModelStats = false
                    self.modelStatsStatus = "Stats failed: \(error.localizedDescription)"
                }
            }
        }
    }


    var phasePill: some View {
        HStack(spacing: 7) {
            if viewModel.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: phaseIcon)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(phaseTitle)
                .lineLimit(1)
            Text(activeModelLabel)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption.bold())
        .foregroundColor(phaseTone.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(phaseTone.color.opacity(0.10))
        .clipShape(Capsule())
        .frame(maxWidth: 360, alignment: .leading)
    }


    var outputText: String {
        switch selectedOutput {
        case .improved:
            return viewModel.finalPromptForCopy
        case .translation:
            return viewModel.translation
        case .confidence:
            return confidenceOutputText
        }
    }


    var emptyOutputText: String {
        switch viewModel.phase {
        case .idle:
            return "Result will appear here."
        case .translating:
            return "Translating..."
        case .analyzing:
            return selectedOutput == .translation ? viewModel.translation : "Analyzing..."
        case .checkingConfidence:
            return selectedOutput == .confidence ? "Checking confidence..." : outputText.isEmpty ? "Checking confidence..." : outputText
        case .done, .degraded, .failed:
            if selectedOutput == .translation { return "No translation returned." }
            if selectedOutput == .confidence { return "No confidence score returned." }
            return "No improved prompt returned."
        }
    }


    var transformDisabled: Bool {
        viewModel.isBusy || !ollama.isOllamaRunning || viewModel.inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }


    var transformDisabledReason: String {
        if viewModel.isBusy { return "Rus to Prompt is already running." }
        if !ollama.isOllamaRunning { return "Launch Ollama first." }
        return "Enter a prompt."
    }


    var phaseTitle: String {
        if !ollama.isOllamaRunning && !viewModel.isBusy { return "Offline" }
        switch viewModel.phase {
        case .idle: return "Ready"
        case .translating: return "Translating"
        case .analyzing: return "Analyzing"
        case .checkingConfidence: return "Confidence"
        case .done: return "Done"
        case .degraded: return "Fallback"
        case .failed: return "Failed"
        }
    }


    var phaseDetail: String {
        if let error = viewModel.errorMessage, viewModel.phase == .failed { return error }
        if let warning = viewModel.warningMessage, viewModel.phase == .degraded { return warning }
        switch viewModel.phase {
        case .idle:
            let confidence = viewModel.confidenceEnabled ? " | Confidence \(shortModelName(viewModel.confidenceModel))" : ""
            return "Translator \(shortModelName(viewModel.translatorModel)) | Analyzer \(shortModelName(viewModel.analyzerModel))\(confidence)"
        case .translating:
            return viewModel.translatorModel
        case .analyzing:
            return viewModel.analyzerModel
        case .checkingConfidence:
            return viewModel.confidenceModel
        case .done:
            if let confidence = viewModel.confidenceResult?.confidence {
                return String(format: "Improved prompt ready | confidence %.0f%%", confidence * 100)
            }
            if let warning = viewModel.confidenceWarning { return warning }
            return "Improved prompt ready"
        case .degraded:
            if let confidence = viewModel.confidenceResult?.confidence {
                return String(format: "Using fallback | confidence %.0f%%", confidence * 100)
            }
            return viewModel.confidenceWarning ?? "Using translation as fallback"
        case .failed:
            return "No result"
        }
    }

}

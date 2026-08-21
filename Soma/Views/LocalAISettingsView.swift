import AppKit
import SwiftUI

struct LocalAISettingsView: View {
    @ObservedObject var viewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager
    @State private var showRoleEditing = false
    @State private var showInstalledModels = false
    @State private var showRecentUsage = false
    @State private var showRuntimeDetails = false
    @State private var deepSeekAPIKeyInput = ""
    @State private var deepSeekCredentialMessage = ""
    @State private var geminiAPIKeyInput = ""
    @State private var geminiCredentialMessage = ""

    var body: some View {
        SomaPage {
            WorkflowHeader(
                title: "Local AI",
                subtitle: "Role-based Ollama model settings. Scout, planning/ranking, analysis, and translation can use different local models.",
                icon: "cpu",
                tone: .info,
                trailing: AnyView(headerActions)
            )

            SomaSplitWorkbench {
                runtimeBanner
                roleTablePanel
            } secondary: {
                modelSummaryPanel
                apiProvidersPanel
                advancedRoleSettingsPanel
                installedModelsPanel
                recentUsagePanel
                runtimeDetailsPanel
            }
        }
        .onAppear {
            ollama.refreshInstalledModels()
            ollama.checkStatus()
            viewModel.loadStructuredLogs()
            refreshDeepSeekCredentialStatus()
            refreshGeminiCredentialStatus()
        }
    }

    private var roleTablePanel: some View {
        SomaPanel(title: "Global model roles", subtitle: "These app-wide defaults apply to every project in v1. Project-specific overrides are intentionally not part of this redesign.", icon: "tablecells", tone: .info) {
            VStack(spacing: 0) {
                roleTableHeader
                Divider()
                ForEach(LocalModelRole.allCases) { role in
                    roleRow(role)
                    if role.id != LocalModelRole.allCases.last?.id {
                        Divider()
                    }
                }
            }
            .background(Color(NSColor.textBackgroundColor).opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
        }
    }

    private var roleTableHeader: some View {
        HStack(spacing: 12) {
            Text("Role")
                .frame(width: 126, alignment: .leading)
            Text("Model")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Installed")
                .frame(width: 86, alignment: .leading)
            Text("Loaded")
                .frame(width: 78, alignment: .leading)
            Text("Action")
                .frame(width: 154, alignment: .trailing)
        }
        .font(.caption.bold())
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func roleRow(_ role: LocalModelRole) -> some View {
        let selectedModel = ollama.modelName(for: role)
        let isAuto = role.allowsAuto && selectedModel.isEmpty
        let installed = isAuto || ollama.isConfiguredModelInstalled(role)
        let loaded = !selectedModel.isEmpty && ollama.isLoaded(selectedModel)

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(role.title)
                    .font(.subheadline.bold())
                Text(role.subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .frame(width: 126, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(isAuto ? "Auto" : selectedModel)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(role.envKey)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            StatusChip(text: installedStatusText(isAuto: isAuto, installed: installed), tone: installedStatusTone(isAuto: isAuto, installed: installed))
                .frame(width: 86, alignment: .leading)

            StatusChip(text: loadedStatusText(isAuto: isAuto, loaded: loaded), tone: loaded ? .good : .neutral)
                .frame(width: 78, alignment: .leading)

            HStack(spacing: 8) {
                Menu {
                    if role.allowsAuto {
                        Button("Auto") { ollama.updateModel("", for: role) }
                    }
                    if ollama.installedModels.isEmpty {
                        Text(ollama.isOllamaRunning ? "No installed models" : "Start Ollama to list models")
                    } else {
                        ForEach(ollama.installedModels) { model in
                            Button(model.name) { ollama.updateModel(model.name, for: role) }
                        }
                    }
                } label: {
                    Label("Change", systemImage: "chevron.up.chevron.down")
                }
                .menuStyle(.button)
                .controlSize(.small)

                Button {
                    if loaded {
                        ollama.unloadModel(selectedModel)
                    } else {
                        ollama.loadModel(selectedModel)
                    }
                } label: {
                    Label(loaded ? "Unload" : "Load", systemImage: loaded ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isAuto || selectedModel.isEmpty || !ollama.isOllamaRunning || ollama.isBusy)
                .help(loadActionHelp(isAuto: isAuto, selectedModel: selectedModel, loaded: loaded))
            }
            .frame(width: 154, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var modelSummaryPanel: some View {
        SomaPanel(title: "Configured Roles", subtitle: "These values are injected into Python runs as SOMA_* environment variables.", icon: "slider.horizontal.3", tone: .info) {
            ForEach(LocalModelRole.allCases) { role in
                SomaKeyValueRow(
                    label: role.title,
                    value: role.allowsAuto && ollama.modelName(for: role).isEmpty ? "Auto" : ollama.modelName(for: role),
                    tone: role == .scout ? .warning : .info
                )
            }
        }
    }

    private var apiProvidersPanel: some View {
        SomaPanel(title: "API Providers", subtitle: "Paid provider keys used by online Rus to Prompt models.", icon: "key", tone: .warning) {
            VStack(alignment: .leading, spacing: 10) {
                apiKeySection(title: "DeepSeek", placeholder: "DeepSeek API key", input: $deepSeekAPIKeyInput, message: deepSeekCredentialMessage, hasEnv: DeepSeekCredentialStore.hasEnvironmentAPIKey(), hasSaved: DeepSeekCredentialStore.hasKeychainAPIKey(), save: saveDeepSeekAPIKey, clear: clearDeepSeekAPIKey)

                Divider().padding(.vertical, 2)

                apiKeySection(title: "Gemini", note: "AI Studio API key (aistudio.google.com) — not the AI Pro / gemini-cli login.", placeholder: "Gemini API key", input: $geminiAPIKeyInput, message: geminiCredentialMessage, hasEnv: GeminiCredentialStore.hasEnvironmentAPIKey(), hasSaved: GeminiCredentialStore.hasKeychainAPIKey(), save: saveGeminiAPIKey, clear: clearGeminiAPIKey)
            }
        }
    }

    @ViewBuilder
    private func apiKeySection(title: String, note: String? = nil, placeholder: String, input: Binding<String>, message: String, hasEnv: Bool, hasSaved: Bool, save: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline.bold())
            StatusChip(text: hasEnv ? "Env active" : (hasSaved ? "Key saved" : "Not set"), tone: (hasEnv || hasSaved) ? .good : .warning)
            Spacer()
        }
        if let note {
            Text(note).font(.caption2).foregroundColor(.secondary)
        }
        SecureField(hasSaved ? "Saved locally" : placeholder, text: input)
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced))
        HStack(spacing: 8) {
            Button(action: save) { Label("Save Key", systemImage: "key.fill") }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(action: clear) { Label("Clear", systemImage: "trash") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!hasSaved)
        }
        if !message.isEmpty {
            Text(message).font(.caption).foregroundColor(message.hasPrefix("Could not") ? .red : .secondary)
        }
    }

    private func refreshGeminiCredentialStatus() {
        if GeminiCredentialStore.hasEnvironmentAPIKey() {
            geminiCredentialMessage = "Environment key will be used before the saved key."
        } else if GeminiCredentialStore.hasKeychainAPIKey() {
            geminiCredentialMessage = "Gemini key is saved locally."
        } else {
            geminiCredentialMessage = "Gemini online judge/translation needs an AI Studio API key."
        }
    }

    private func saveGeminiAPIKey() {
        do {
            try GeminiCredentialStore.saveAPIKey(geminiAPIKeyInput)
            geminiAPIKeyInput = ""
            geminiCredentialMessage = "Gemini key saved."
        } catch {
            geminiCredentialMessage = "Could not save Gemini key: \(error.localizedDescription)"
        }
    }

    private func clearGeminiAPIKey() {
        do {
            try GeminiCredentialStore.clearAPIKey()
            geminiCredentialMessage = "Gemini key removed."
        } catch {
            geminiCredentialMessage = "Could not clear Gemini key: \(error.localizedDescription)"
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button {
                ollama.refreshInstalledModels()
                ollama.checkStatus()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                ollama.launchOllama()
            } label: {
                if ollama.isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Working")
                    }
                } else {
                    Label(ollama.isOllamaRunning ? "Ollama Running" : "Launch Ollama", systemImage: "play.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(ollama.isBusy || ollama.isOllamaRunning)
        }
    }

    private var runtimeBanner: some View {
        if !ollama.isOllamaRunning {
            return StatusBanner(
                title: "Ollama is offline",
                detail: "Saved model selections still apply to future runs, but installed and loaded model status is unavailable until Ollama is running.",
                tone: .warning
            )
        }
        if let error = ollama.tagsError {
            return StatusBanner(
                title: "Could not load installed models",
                detail: error,
                tone: .warning
            )
        }
        return StatusBanner(
            title: "Ollama is available",
            detail: "\(ollama.installedModels.count) installed models found. \(ollama.loadedModelNames.count) model(s) currently loaded.",
            tone: .good
        )
    }

    private func refreshDeepSeekCredentialStatus() {
        if DeepSeekCredentialStore.hasEnvironmentAPIKey() {
            deepSeekCredentialMessage = "Environment key will be used before the saved key."
        } else if DeepSeekCredentialStore.hasKeychainAPIKey() {
            deepSeekCredentialMessage = "DeepSeek key is saved locally."
        } else {
            deepSeekCredentialMessage = "DeepSeek models need an API key before paid requests can run."
        }
    }

    private func saveDeepSeekAPIKey() {
        do {
            try DeepSeekCredentialStore.saveAPIKey(deepSeekAPIKeyInput)
            deepSeekAPIKeyInput = ""
            deepSeekCredentialMessage = "DeepSeek key saved."
        } catch {
            deepSeekCredentialMessage = "Could not save DeepSeek key: \(error.localizedDescription)"
        }
    }

    private func clearDeepSeekAPIKey() {
        do {
            try DeepSeekCredentialStore.clearAPIKey()
            deepSeekAPIKeyInput = ""
            deepSeekCredentialMessage = "DeepSeek key removed."
        } catch {
            deepSeekCredentialMessage = "Could not clear DeepSeek key: \(error.localizedDescription)"
        }
    }

    private var advancedRoleSettingsPanel: some View {
        DetailDisclosure(
            title: "Custom Role Models",
            subtitle: "Use this only when the model is not in the installed list or Translator should not use Auto.",
            icon: "text.cursor",
            isExpanded: $showRoleEditing
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(LocalModelRole.allCases) { role in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(role.title)
                                .font(.caption.bold())
                            Spacer()
                            Text(role.envKey)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        TextField(role.allowsAuto ? "Blank = Auto fallback" : "Custom Ollama model name", text: binding(for: role))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
    }

    private var runtimeDetailsPanel: some View {
        DetailDisclosure(
            title: "Ollama Runtime Details",
            subtitle: "Raw status hints and resource limits available today.",
            icon: "terminal",
            isExpanded: $showRuntimeDetails
        ) {
            VStack(alignment: .leading, spacing: 8) {
                SomaKeyValueRow(label: "API", value: ollama.isOllamaRunning ? "127.0.0.1:11434 online" : "offline", tone: ollama.isOllamaRunning ? .good : .warning)
                SomaKeyValueRow(label: "Installed source", value: "/api/tags", tone: .neutral)
                SomaKeyValueRow(label: "Loaded source", value: "/api/ps", tone: .neutral)
                SomaKeyValueRow(label: "Loaded models", value: ollama.loadedModelNames.isEmpty ? "None" : ollama.loadedModelNames.sorted().joined(separator: ", "), tone: ollama.loadedModelNames.isEmpty ? .neutral : .good)
                Text("Memory, GPU, idle timers, auto-unload policies, and in-app model downloads are future scope; this screen only exposes the status Ollama provides today.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func roleCard(_ role: LocalModelRole) -> some View {
        let selectedModel = ollama.modelName(for: role)
        let isAuto = role.allowsAuto && selectedModel.isEmpty
        let installed = isAuto || ollama.isConfiguredModelInstalled(role)
        let loaded = !selectedModel.isEmpty && ollama.isLoaded(selectedModel)

        return SomaPanel(title: role.title, subtitle: role.subtitle, icon: icon(for: role), tone: tone(for: role)) {
            HStack(alignment: .top, spacing: 8) {
                Picker("Installed model", selection: binding(for: role)) {
                    if role.allowsAuto {
                        Text("Auto").tag("")
                    }
                    ForEach(ollama.installedModels) { model in
                        Text(model.name).tag(model.name)
                    }
                    if !selectedModel.isEmpty && !ollama.installedModels.contains(where: { $0.name == selectedModel }) {
                        Text("\(selectedModel) (custom)").tag(selectedModel)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            TextField(role.allowsAuto ? "Custom model or blank for Auto" : "Custom model name", text: binding(for: role))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))

            HStack(spacing: 6) {
                StatusChip(text: role.envKey, tone: .neutral)
                if isAuto {
                    StatusChip(text: "Auto fallback", tone: .info)
                } else {
                    StatusChip(text: installed ? "Installed" : "Not installed", tone: installed ? .good : .warning)
                    StatusChip(text: loaded ? "Loaded" : "Not loaded", tone: loaded ? .good : .neutral)
                }
                Spacer(minLength: 0)
            }

            if !selectedModel.isEmpty {
                HStack(spacing: 8) {
                    Button {
                        ollama.loadModel(selectedModel)
                    } label: {
                        Label("Load", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!ollama.isOllamaRunning || ollama.isBusy)

                    Button {
                        ollama.unloadModel(selectedModel)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!ollama.isOllamaRunning || ollama.isBusy || !loaded)
                }
            }
        }
    }

    private var installedModelsPanel: some View {
        DetailDisclosure(
            title: "Installed Ollama Models",
            subtitle: "\(ollama.installedModels.count) models from /api/tags",
            icon: "externaldrive",
            isExpanded: $showInstalledModels
        ) {
            if ollama.installedModels.isEmpty {
                Text(ollama.isOllamaRunning ? "No installed models were returned by Ollama." : "Start Ollama to list installed models.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
                    ForEach(ollama.installedModels) { model in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(model.name)
                                    .font(.system(.caption, design: .monospaced).bold())
                                    .lineLimit(1)
                                Spacer()
                                if ollama.isLoaded(model.name) {
                                    StatusChip(text: "loaded", tone: .good)
                                }
                            }
                            Text(model.displayDetail)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .padding(10)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.65))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var recentUsagePanel: some View {
        let entries = viewModel.logEntries.filter { $0.event == "local_model_call" }.prefix(8)
        return DetailDisclosure(
            title: "Recent Local Model Calls",
            subtitle: entries.isEmpty ? "No local calls in loaded logs" : "Actual models used by recent runs",
            icon: "clock.arrow.circlepath",
            isExpanded: $showRecentUsage
        ) {
            if entries.isEmpty {
                Text("Run Prepare Packet, Prompt Builder, Scout, or refresh logs to see local model usage.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(entry.isError ? Color.red : Color.green)
                                .frame(width: 7, height: 7)
                            Text(entry.local_model ?? "unknown")
                                .font(.system(.caption, design: .monospaced).bold())
                            if let stage = entry.local_model_stage {
                                StatusChip(text: stage, tone: .neutral)
                            }
                            if let role = entry.local_model.flatMap({ ollama.configuredRole(for: $0, stage: entry.local_model_stage) }) {
                                StatusChip(text: role.title, tone: .info)
                            }
                            Spacer()
                            Text(entry.shortTime)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func binding(for role: LocalModelRole) -> Binding<String> {
        Binding(
            get: { ollama.modelName(for: role) },
            set: { ollama.updateModel($0, for: role) }
        )
    }

    private func installedStatusText(isAuto: Bool, installed: Bool) -> String {
        if isAuto { return "Fallback" }
        return installed ? "Installed" : "Missing"
    }

    private func installedStatusTone(isAuto: Bool, installed: Bool) -> SomaStatusTone {
        if isAuto { return .info }
        return installed ? .good : .warning
    }

    private func loadedStatusText(isAuto: Bool, loaded: Bool) -> String {
        if isAuto { return "Auto" }
        return loaded ? "Loaded" : "Not loaded"
    }

    private func loadActionHelp(isAuto: Bool, selectedModel: String, loaded: Bool) -> String {
        if isAuto { return "Translator Auto uses backend fallback and cannot be loaded directly." }
        if selectedModel.isEmpty { return "Choose a model before loading it." }
        if !ollama.isOllamaRunning { return "Launch Ollama before loading or unloading models." }
        return loaded ? "Unload this model from Ollama." : "Load this model and keep it warm in Ollama."
    }

    private func icon(for role: LocalModelRole) -> String {
        switch role {
        case .scout: return "folder.badge.magnifyingglass"
        case .ranker: return "list.number"
        case .analyst: return "brain"
        case .translator: return "character.bubble"
        }
    }

    private func tone(for role: LocalModelRole) -> SomaStatusTone {
        switch role {
        case .scout: return .info
        case .ranker: return .warning
        case .analyst: return .good
        case .translator: return .neutral
        }
    }
}

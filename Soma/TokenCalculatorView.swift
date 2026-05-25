import AppKit
import SwiftUI
import Combine

struct TokenCalculatorView: View {
    @ObservedObject var viewModel: SomaViewModel
    @State private var inputText: String = ""
    @State private var rawText: String = ""
    @State private var somaPacketText: String = ""
    @State private var selectedModel: String = "GPT-5.5"
    @State private var showAdvancedBreakdown = false
    @State private var copiedSummary = false

    struct ModelCategory: Identifiable {
        let id = UUID()
        let name: String
        let models: [String]
    }

    struct ModelProfile {
        let key: String
        let label: String
        let charsPerToken: Double
        let aliases: [String]
    }

    struct ProfileFile: Decodable {
        let profiles: [ProfileItem]
    }

    struct ProfileItem: Decodable {
        let key: String
        let label: String
        let chars_per_token: Double
        let aliases: [String]
    }

    private let categories = [
        ModelCategory(name: "OpenAI", models: [
            "GPT-5.5", "GPT-5.4 Pro", "o3-pro", "o3", "GPT-5 Turbo", "GPT-5 Mini", "GPT-4.5", "GPT-4o", "GPT-4.1", "o4-mini"
        ]),
        ModelCategory(name: "Google DeepMind", models: [
            "Gemini 3.1 Pro Deep Think", "Gemini 3.1 Pro", "Gemini 3.1 Flash", "Gemini 3.1 Flash Lite", "Gemini 3 Pro", "Gemini 3 Flash", "Gemini 2.5 Ultra", "Gemini 2.5 Pro", "Gemma 4 27B", "Gemma 4 E4B"
        ]),
        ModelCategory(name: "Anthropic", models: [
            "Claude Opus 4.7", "Claude Opus 4.5", "Claude Sonnet 4.5", "Claude Sonnet 4", "Claude Haiku 4", "Claude Opus 3.7", "Claude Sonnet 3.7", "Claude Haiku 3.5", "Claude Sonnet 3.5", "Claude Opus 3"
        ])
    ]

    var body: some View {
        SomaPage(maxWidth: 1180) {
            WorkflowHeader(
                title: "Token Calculator",
                subtitle: "Estimate prompt and packet size inside Soma. This utility is available when you need numbers, without opening a separate floating lab window.",
                icon: "number.square",
                tone: .info,
                trailing: AnyView(StatusChip(text: selectedProfile.label, tone: .info, icon: "function"))
            )

            SomaSplitWorkbench {
                editorPanel
                comparisonPanel
            } secondary: {
                summaryPanel
                explanationPanel
                budgetPanel
                advancedBreakdownPanel
            }
        }
    }

    private var editorPanel: some View {
        SomaPanel(title: "Prompt Text", subtitle: "Paste any prompt, transcript, or packet excerpt to estimate token size.", icon: "text.alignleft", tone: .info) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Target model")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    Spacer()
                    Picker("Model", selection: $selectedModel) {
                        ForEach(categories) { category in
                            Section(category.name) {
                                ForEach(category.models, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 280)
                }

                ZStack(alignment: .topLeading) {
                    if inputText.isEmpty {
                        Text("Paste text to estimate…")
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $inputText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 260)
                        .padding(4)
                        .background(Color.clear)
                }
                .background(Color(NSColor.textBackgroundColor).opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
                .overlay(RoundedRectangle(cornerRadius: SomaDesign.radius).stroke(Color.secondary.opacity(0.16)))

                HStack(spacing: 8) {
                    Button {
                        copySummary()
                    } label: {
                        Label(copiedSummary ? "Copied" : "Copy Summary", systemImage: copiedSummary ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .disabled(inputText.isEmpty)

                    Button("Clear") {
                        inputText = ""
                        copiedSummary = false
                    }
                    .buttonStyle(.bordered)
                    .disabled(inputText.isEmpty)

                    Spacer()
                    Text("\(inputText.count) characters · ~\(estimateTokens(inputText)) tokens")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .controlSize(.small)
            }
        }
    }

    private var summaryPanel: some View {
        SomaPanel(title: "Count Summary", subtitle: "Approximate tokenizer profile for planning budgets, not billing-grade accounting.", icon: "speedometer", tone: tokenTone) {
            VStack(alignment: .leading, spacing: 10) {
                MetricTile(title: "Estimated Tokens", value: "\(estimateTokens(inputText))", detail: selectedModel, tone: tokenTone)
                SomaKeyValueRow(label: "Characters", value: "\(inputText.count)", tone: .neutral)
                SomaKeyValueRow(label: "Words", value: "\(wordCount(inputText))", tone: .neutral)
                SomaKeyValueRow(label: "Estimator", value: "\(selectedProfile.key) · \(String(format: "%.1f", selectedProfile.charsPerToken)) chars/token", tone: .info)
            }
        }
    }

    private var comparisonPanel: some View {
        SomaPanel(title: "Raw vs Soma Packet", subtitle: "Optional comparison for context compression experiments.", icon: "rectangle.split.2x1", tone: .neutral) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    comparisonEditor(title: "Raw context", placeholder: "Paste original context…", text: $rawText)
                    comparisonEditor(title: "Soma packet", placeholder: "Paste prepared packet…", text: $somaPacketText)
                }

                let rawTokens = estimateTokens(rawText)
                let somaTokens = estimateTokens(somaPacketText)
                let saved = max(0, rawTokens - somaTokens)
                let pct = rawTokens > 0 ? (Double(saved) / Double(rawTokens) * 100) : 0

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    MetricTile(title: "Raw", value: "\(rawTokens)", detail: "tokens", tone: .neutral)
                    MetricTile(title: "Soma", value: "\(somaTokens)", detail: "tokens", tone: .info)
                    MetricTile(title: "Saved", value: "\(saved)", detail: "tokens", tone: saved > 0 ? .good : .neutral)
                    MetricTile(title: "Savings", value: String(format: "%.1f%%", pct), detail: "raw vs packet", tone: pct > 0 ? .good : .neutral)
                }
            }
        }
    }

    private var explanationPanel: some View {
        SomaPanel(title: "What This Means", subtitle: "Use this before sending huge prompts or evaluating packet size.", icon: "info.circle", tone: .info) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Estimates use model-family character/token profiles bundled with Soma.", systemImage: "checkmark.circle")
                Label("Exact counts can differ from provider tokenizers and tool-call serialization.", systemImage: "exclamationmark.triangle")
                Label("Prepare Packet remains the primary workflow for real context gathering.", systemImage: "doc.text.magnifyingglass")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var budgetPanel: some View {
        SomaPanel(title: "Soma Budgets", subtitle: "Reference targets for packet modes.", icon: "ruler", tone: .neutral) {
            VStack(spacing: 4) {
                budgetRow(name: "micro", limit: "1k", desc: "Status & map")
                budgetRow(name: "fast", limit: "2.5k", desc: "Quick tasks")
                budgetRow(name: "balanced", limit: "6k", desc: "Default dev")
                budgetRow(name: "deep", limit: "15k", desc: "Architecture")
                budgetRow(name: "full", limit: "30k", desc: "Legacy context")
            }
        }
    }

    private var advancedBreakdownPanel: some View {
        SomaPanel(title: "Advanced Breakdown", subtitle: "Collapsed by default so the utility stays lightweight.", icon: "slider.horizontal.3", tone: .neutral) {
            DisclosureGroup(isExpanded: $showAdvancedBreakdown) {
                VStack(alignment: .leading, spacing: 6) {
                    SomaKeyValueRow(label: "Profile label", value: selectedProfile.label, tone: .info)
                    SomaKeyValueRow(label: "Profile key", value: selectedProfile.key, tone: .neutral)
                    SomaKeyValueRow(label: "Aliases", value: selectedProfile.aliases.isEmpty ? "—" : selectedProfile.aliases.joined(separator: ", "), tone: .neutral)
                    SomaKeyValueRow(label: "Line count", value: "\(lineCount(inputText))", tone: .neutral)
                    SomaKeyValueRow(label: "Whitespace", value: "\(inputText.filter { $0.isWhitespace }.count)", tone: .neutral)
                }
                .padding(.top, 8)
            } label: {
                Text(showAdvancedBreakdown ? "Hide estimator details" : "Show estimator details")
                    .font(.caption.bold())
            }
        }
    }

    private func comparisonEditor(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(.secondary)
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(7)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 132)
                    .padding(4)
                    .background(Color.clear)
            }
            .background(Color(NSColor.textBackgroundColor).opacity(0.66))
            .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
            .overlay(RoundedRectangle(cornerRadius: SomaDesign.radius).stroke(Color.secondary.opacity(0.16)))
        }
    }

    private func budgetRow(name: String, limit: String, desc: String) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.caption.bold()).frame(width: 70, alignment: .leading)
            Text(limit).font(.system(.caption, design: .monospaced).bold()).foregroundColor(.secondary).frame(width: 44, alignment: .leading)
            Text(desc).font(.caption).foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var selectedProfile: ModelProfile { profile(for: selectedModel) }

    private var tokenTone: SomaStatusTone {
        let tokens = estimateTokens(inputText)
        if inputText.isEmpty { return .neutral }
        if tokens >= 30_000 { return .warning }
        if tokens >= 15_000 { return .info }
        return .good
    }

    private func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let profile = profile(for: selectedModel)
        return max(1, Int(ceil(Double(text.count) / profile.charsPerToken)))
    }

    private func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private func copySummary() {
        let summary = """
        Token estimate
        Model: \(selectedModel)
        Profile: \(selectedProfile.label) (\(String(format: "%.1f", selectedProfile.charsPerToken)) chars/token)
        Characters: \(inputText.count)
        Words: \(wordCount(inputText))
        Estimated tokens: \(estimateTokens(inputText))
        """
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(summary, forType: .string)
        copiedSummary = true
    }

    private func profile(for model: String) -> ModelProfile {
        let lower = model.lowercased()
        for profile in loadProfiles() {
            if lower.contains(profile.key) || profile.aliases.contains(where: { !$0.isEmpty && lower.contains($0) }) {
                return profile
            }
        }
        return ModelProfile(key: "fallback", label: "Fallback", charsPerToken: 4.0, aliases: [])
    }

    private func loadProfiles() -> [ModelProfile] {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("token_profiles.json")
        let bundledURL = Bundle.main.url(forResource: "token_profiles", withExtension: "json")
        let profileURL = FileManager.default.fileExists(atPath: sourceURL.path) ? sourceURL : bundledURL
        if let profileURL,
           let data = try? Data(contentsOf: profileURL),
           let decoded = try? JSONDecoder().decode(ProfileFile.self, from: data) {
            return decoded.profiles.map {
                ModelProfile(key: $0.key, label: $0.label, charsPerToken: $0.chars_per_token, aliases: $0.aliases)
            }
        }
        return [
            ModelProfile(key: "gpt-5.5", label: "GPT-5.5", charsPerToken: 3.2, aliases: ["gpt-5.5"]),
            ModelProfile(key: "openai", label: "OpenAI generic", charsPerToken: 3.4, aliases: ["gpt", "openai", "o3", "o4"]),
            ModelProfile(key: "gemini", label: "Gemini generic", charsPerToken: 3.5, aliases: ["gemini", "gemma"]),
            ModelProfile(key: "claude", label: "Claude generic", charsPerToken: 3.3, aliases: ["claude", "anthropic"]),
            ModelProfile(key: "local", label: "Local model generic", charsPerToken: 3.8, aliases: ["local", "ollama"]),
            ModelProfile(key: "fallback", label: "Fallback", charsPerToken: 4.0, aliases: []),
        ]
    }
}

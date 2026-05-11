import SwiftUI
import Combine

struct TokenCalculatorView: View {
    @ObservedObject var viewModel: SomaViewModel
    @State private var inputText: String = ""
    @State private var rawText: String = ""
    @State private var somaPacketText: String = ""
    @State private var estimatedTokens: Int = 0
    @State private var selectedModel: String = "GPT-5.5"

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

    let categories = [
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
        VStack(spacing: 20) {
            headerSection
            
            modelPickerSection

            editorSection

            resultSection

            Divider()

            comparisonSection

            Divider()

            budgetSection
        }
        .padding()
        .frame(minWidth: 640, minHeight: 760)
    }

    private var headerSection: some View {
        Text("Token Savings Lab")
            .font(.title2)
            .bold()
    }

    private var modelPickerSection: some View {
        HStack {
            Text("Target Model:")
            Picker("Model", selection: $selectedModel) {
                ForEach(categories) { category in
                    Section(header: Text(category.name)) {
                        ForEach(category.models, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(width: 300)
        }
    }

    private var editorSection: some View {
        TextEditor(text: $inputText)
            .font(.system(.body, design: .monospaced))
            .padding(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal)
            .onChange(of: inputText) { updateTokens() }
            .onChange(of: selectedModel) { updateTokens() }
    }

    private var resultSection: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Characters: \(inputText.count)")
                Text("Estimated Tokens (\(selectedModel)): \(estimatedTokens)")
                    .bold()
                    .foregroundColor(.blue)
                Text("Estimator: \(profileForSelectedModel().key), \(String(format: "%.1f", profileForSelectedModel().charsPerToken)) chars/token")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Clear All") {
                inputText = ""
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
        .padding(.horizontal)
    }

    private var comparisonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Raw vs Soma Packet")
                .font(.headline)

            HStack(alignment: .top, spacing: 12) {
                comparisonEditor(title: "Raw context", text: $rawText)
                comparisonEditor(title: "Soma packet", text: $somaPacketText)
            }

            let rawTokens = estimateTokens(rawText)
            let somaTokens = estimateTokens(somaPacketText)
            let saved = max(0, rawTokens - somaTokens)
            let pct = rawTokens > 0 ? (Double(saved) / Double(rawTokens) * 100) : 0

            HStack(spacing: 16) {
                comparisonMetric(value: "\(rawTokens)", label: "Raw tokens", color: .secondary)
                comparisonMetric(value: "\(somaTokens)", label: "Soma tokens", color: .purple)
                comparisonMetric(value: "\(saved)", label: "Saved", color: .green)
                comparisonMetric(value: String(format: "%.1f%%", pct), label: "Savings", color: .green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func comparisonEditor(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(.secondary)
            TextEditor(text: text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 120)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
        }
    }

    private func comparisonMetric(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.headline, design: .monospaced).bold())
                .foregroundColor(color)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Soma 2026 Token Budgets:")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                budgetRow(name: "micro", limit: "1k", desc: "Status & Map")
                budgetRow(name: "fast", limit: "2.5k", desc: "Quick Tasks")
                budgetRow(name: "balanced", limit: "6k", desc: "Default Dev")
                budgetRow(name: "deep", limit: "15k", desc: "Architecture")
                budgetRow(name: "full", limit: "30k", desc: "Legacy Context")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func budgetRow(name: String, limit: String, desc: String) -> some View {
        GridRow {
            Text(name).bold()
            Text(limit).foregroundColor(.secondary)
            Text(desc).font(.caption).italic()
        }
    }

    private func updateTokens() {
        estimatedTokens = estimateTokens(inputText)
    }

    private func estimateTokens(_ text: String) -> Int {
        let profile = profileForSelectedModel()
        return max(1, Int(ceil(Double(text.count) / profile.charsPerToken)))
    }

    private func profileForSelectedModel() -> ModelProfile {
        let lower = selectedModel.lowercased()
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

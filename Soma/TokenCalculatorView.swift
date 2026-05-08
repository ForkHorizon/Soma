import SwiftUI
import Combine

struct TokenCalculatorView: View {
    @ObservedObject var viewModel: SomaViewModel
    @State private var inputText: String = ""
    @State private var estimatedTokens: Int = 0
    @State private var selectedModel: String = "GPT-5.5"

    struct ModelCategory: Identifiable {
        let id = UUID()
        let name: String
        let models: [String]
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

            budgetSection
        }
        .padding()
        .frame(minWidth: 550, minHeight: 650)
    }

    private var headerSection: some View {
        Text("Token Calculator 2026")
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
        let ratio: Double
        
        // Advanced 2026 tokenization ratios
        if selectedModel.contains("GPT-5") || selectedModel.contains("o3") || selectedModel.contains("o4") {
            ratio = 3.2 // Next-gen OpenAI ultra-dense encoding
        } else if selectedModel.contains("Gemini 3") || selectedModel.contains("Gemma 4") {
            ratio = 3.5 // Next-gen Google context compression
        } else if selectedModel.contains("Claude") && (selectedModel.contains("4") || selectedModel.contains("3.7")) {
            ratio = 3.3 // Anthropic optimized byte-pair encoding
        } else if selectedModel.contains("mini") || selectedModel.contains("Lite") || selectedModel.contains("Haiku") {
            ratio = 3.8 // Efficiency models typically use slightly less dense encoding
        } else {
            ratio = 3.6 // Generic 2026 baseline
        }
        
        estimatedTokens = max(1, Int(Double(inputText.count) / ratio))
    }
}

import AppKit
import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var viewModel: SomaViewModel
    @ObservedObject var scoutViewModel: ScoutViewModel
    @ObservedObject var ollama: OllamaManager
    @Binding var selectedRoute: AppRoute?
    @State private var selectedTab: DiagnosticsTab = .status

    private enum DiagnosticsTab: String, CaseIterable, Identifiable {
        case status = "Status"
        case localAI = "Local AI"
        case graphAndTools = "Tools"
        case activity = "Raw Activity"
        case tokenCalculator = "Tokens"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            selectedContent
        }
        .background(SomaDesign.pageBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkflowHeader(
                title: "Diagnostics",
                subtitle: "Advanced runtime, MCP, Graphify, Local AI, logs, and utility screens live here so the main workflow stays quiet.",
                icon: "stethoscope",
                tone: .neutral
            )

            Picker("Diagnostics", selection: $selectedTab) {
                ForEach(DiagnosticsTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 620)
        }
        .padding(22)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .status:
            SystemStatusView(viewModel: viewModel, ollama: ollama)
        case .localAI:
            LocalAISettingsView(viewModel: viewModel, ollama: ollama)
        case .graphAndTools:
            AdvancedToolsView(somaViewModel: viewModel, scoutViewModel: scoutViewModel, ollama: ollama, selectedRoute: $selectedRoute)
        case .activity:
            LogsView(viewModel: viewModel, ollama: ollama)
        case .tokenCalculator:
            TokenCalculatorView(viewModel: viewModel)
        }
    }
}

import AppKit
import Combine
import Foundation
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager
    @ObservedObject var rusToPromptQueueManager: RusToPromptQueueManager
    @StateObject private var promptCompilerViewModel = PromptCompilerViewModel()
    @StateObject private var rusToPromptViewModel = RusToPromptViewModel()
    @State private var selectedRoute: AppRoute? = .rusToPrompt
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel, ollama: ollama, selectedRoute: $selectedRoute)
                .navigationTitle("Soma")
        } detail: {
            VStack(spacing: 0) {
                if selectedRoute != .rusToPrompt && selectedRoute != .tests
                    && selectedRoute != .queue && selectedRoute != .modelStats
                    && selectedRoute != .extensions && selectedRoute != .voiceToText {
                    GlobalSettingsBar(viewModel: viewModel, ollama: ollama, selectedRoute: $selectedRoute)
                }

                if let route = selectedRoute {
                    switch route {
                    case .rusToPrompt:
                        RusToPromptView(viewModel: rusToPromptViewModel, somaViewModel: viewModel, ollama: ollama, queueManager: rusToPromptQueueManager)
                            .navigationTitle(route.title)
                    case .voiceToText:
                        VoiceToTextView(somaViewModel: viewModel, ollama: ollama)
                            .navigationTitle(route.title)
                    case .queue:
                        TestsView(mode: .queue, ollama: ollama, queueManager: rusToPromptQueueManager)
                            .navigationTitle(route.title)
                    case .modelStats:
                        TestsView(mode: .stats, ollama: ollama, queueManager: rusToPromptQueueManager)
                            .navigationTitle(route.title)
                    case .tests:
                        TestsView(mode: .full, ollama: ollama, queueManager: rusToPromptQueueManager)
                            .navigationTitle(route.title)
                    case .promptCompiler:
                        PromptCompilerView(viewModel: promptCompilerViewModel, somaViewModel: viewModel, ollama: ollama)
                            .navigationTitle(route.title)
                    case .localAI:
                        LocalAISettingsView(viewModel: viewModel, ollama: ollama)
                            .navigationTitle(route.title)
                    case .logs:
                        LogsView(viewModel: viewModel, ollama: ollama)
                            .navigationTitle(route.title)
                    case .tokenCalculator:
                        TokenCalculatorView(viewModel: viewModel)
                            .navigationTitle(route.title)
                    case .systemStatus:
                        SystemStatusView(viewModel: viewModel, ollama: ollama)
                            .navigationTitle(route.title)
                    case .extensions:
                        ToolVersionsView()
                            .navigationTitle(route.title)
                    }
                } else {
                    Spacer()
                    Text("Select Rus to Prompt to start")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .frame(minWidth: 1120, minHeight: 680)
        .task {
            viewModel.hydrateProjectRootsIfNeeded()
        }
    }

}

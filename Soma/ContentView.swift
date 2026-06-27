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
                if let route = selectedRoute {
                    switch route {
                    case .rusToPrompt:
                        RusToPromptView(viewModel: rusToPromptViewModel, somaViewModel: viewModel, ollama: ollama, queueManager: rusToPromptQueueManager)
                    case .voiceToText:
                        VoiceToTextView(somaViewModel: viewModel, ollama: ollama)
                    case .queue:
                        TestsView(mode: .queue, ollama: ollama, queueManager: rusToPromptQueueManager)
                    case .modelStats:
                        TestsView(mode: .stats, ollama: ollama, queueManager: rusToPromptQueueManager)
                    case .tests:
                        TestsView(mode: .full, ollama: ollama, queueManager: rusToPromptQueueManager)
                    case .promptCompiler:
                        PromptCompilerView(viewModel: promptCompilerViewModel, somaViewModel: viewModel, ollama: ollama)
                    case .localAI:
                        LocalAISettingsView(viewModel: viewModel, ollama: ollama)
                    case .logs:
                        LogsView(viewModel: viewModel, ollama: ollama)
                    case .tokenCalculator:
                        TokenCalculatorView(viewModel: viewModel)
                    case .systemStatus:
                        SystemStatusView(viewModel: viewModel, ollama: ollama)
                    case .extensions:
                        ToolVersionsView(viewModel: viewModel)
                    }
                } else {
                    Spacer()
                    Text("Select Rus to Prompt to start")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .toolbar(.hidden, for: .windowToolbar)
        .frame(minWidth: 900, minHeight: 620)
        .task {
            viewModel.hydrateProjectRootsIfNeeded()
        }
    }

}

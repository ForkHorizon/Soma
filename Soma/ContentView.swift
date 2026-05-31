import AppKit
import Combine
import Foundation
import SwiftUI

struct ContentView: View {
    @StateObject private var ollama = OllamaManager()
    @ObservedObject var viewModel: SomaViewModel
    @StateObject private var scoutViewModel = ScoutViewModel()
    @StateObject private var relayViewModel = RelayViewModel()
    @StateObject private var promptCompilerViewModel = PromptCompilerViewModel()
    @StateObject private var rusToPromptViewModel = RusToPromptViewModel()
    @StateObject private var rusToPromptQueueManager = RusToPromptQueueManager()
    @State private var selectedRoute: AppRoute? = .relay
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel, ollama: ollama, selectedRoute: $selectedRoute)
                .navigationTitle("Soma")
        } detail: {
            VStack(spacing: 0) {
                if selectedRoute != .rusToPrompt && selectedRoute != .tests {
                    GlobalSettingsBar(viewModel: viewModel, ollama: ollama, selectedRoute: $selectedRoute)
                }
                
                if let route = selectedRoute {
                    switch route {
                    case .relay:
                        RelayView(viewModel: relayViewModel, somaViewModel: viewModel, ollama: ollama)
                            .navigationTitle(route.title)
                    case .rusToPrompt:
                        RusToPromptView(viewModel: rusToPromptViewModel, somaViewModel: viewModel, ollama: ollama, queueManager: rusToPromptQueueManager)
                            .navigationTitle(route.title)
                    case .tests:
                        TestsView(ollama: ollama, queueManager: rusToPromptQueueManager)
                            .navigationTitle(route.title)
                    case .projectSetup:
                        ProjectSetupView(viewModel: viewModel, selectedRoute: $selectedRoute)
                            .navigationTitle(route.title)
                    case .packets:
                        PacketsView(viewModel: viewModel, selectedRoute: $selectedRoute)
                            .navigationTitle(route.title)
                    case .diagnostics:
                        DiagnosticsView(viewModel: viewModel, scoutViewModel: scoutViewModel, ollama: ollama, selectedRoute: $selectedRoute)
                            .navigationTitle(route.title)
                    case .projects:
                        ProjectsView(viewModel: viewModel, selectedRoute: $selectedRoute)
                            .navigationTitle(route.title)
                    case .promptCompiler:
                        PromptCompilerView(viewModel: promptCompilerViewModel, somaViewModel: viewModel, ollama: ollama)
                            .navigationTitle(route.title)
                    case .localAI:
                        LocalAISettingsView(viewModel: viewModel, ollama: ollama)
                            .navigationTitle(route.title)
                    case .projectHealth:
                        ProjectHealthView(viewModel: viewModel, ollama: ollama)
                            .navigationTitle(route.title)
                    case .logs:
                        LogsView(viewModel: viewModel, ollama: ollama)
                            .navigationTitle(route.title)
                    case .externalTools:
                        AdvancedToolsView(somaViewModel: viewModel, scoutViewModel: scoutViewModel, ollama: ollama, selectedRoute: $selectedRoute)
                            .navigationTitle(route.title)
                    case .tokenCalculator:
                        TokenCalculatorView(viewModel: viewModel)
                            .navigationTitle(route.title)
                    case .systemStatus:
                        SystemStatusView(viewModel: viewModel, ollama: ollama)
                            .navigationTitle(route.title)
                    #if DEBUG
                    case .redesignMock:
                        RedesignMockView()
                            .navigationTitle(route.title)
                    #endif
                    }
                } else {
                    Spacer()
                    Text("Select Prepare Packet to start")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .frame(minWidth: 1120, minHeight: 680)
        .task {
            viewModel.hydrateProjectRootsIfNeeded()
            viewModel.hydratePacketHistoryIfNeeded()
        }
    }

}

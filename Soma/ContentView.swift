import AppKit
import Combine
import Foundation
import SwiftUI

struct ContentView: View {
    @StateObject private var ollama = OllamaManager()
    @ObservedObject var viewModel: SomaViewModel
    @StateObject private var scoutViewModel = ScoutViewModel()
    @StateObject private var relayViewModel = RelayViewModel()
    @State private var selectedRoute: AppRoute? = .relay
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel, ollama: ollama, selectedRoute: $selectedRoute)
                .navigationTitle("Soma")
        } detail: {
            VStack(spacing: 0) {
                GlobalSettingsBar(viewModel: viewModel, ollama: ollama)
                
                if let route = selectedRoute {
                    switch route {
                    case .scout:
                        ScoutView(viewModel: scoutViewModel, somaViewModel: viewModel, ollama: ollama)
                            .navigationTitle(route.rawValue)
                    case .relay:
                        RelayView(viewModel: relayViewModel, somaViewModel: viewModel, ollama: ollama)
                            .navigationTitle(route.rawValue)
                    case .systemStatus:
                        SystemStatusView(viewModel: viewModel)
                            .navigationTitle(route.rawValue)
                    case .logs:
                        LogsView(viewModel: viewModel)
                            .navigationTitle(route.rawValue)
                    }
                } else {
                    Spacer()
                    Text("Select a tool from the sidebar")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .task {
            viewModel.hydrateProjectRootsIfNeeded()
        }
    }

}

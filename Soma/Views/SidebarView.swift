import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager
    @Binding var selectedRoute: AppRoute?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        List(selection: $selectedRoute) {
            Section("Workflows") {
                ForEach(AppRoute.allCases, id: \.self) { route in
                    NavigationLink(value: route) {
                        Label(route.rawValue, systemImage: routeIcon(route))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
             Button(action: { openWindow(id: "token-calculator") }) {
                 Label("Token Calculator", systemImage: "number.square")
             }
             .buttonStyle(.plain)
             .padding()
        }
    }
    
    private func routeIcon(_ route: AppRoute) -> String {
        switch route {
        case .relay: return "doc.text.magnifyingglass"
        case .scout: return "magnifyingglass"
        case .systemStatus: return "info.circle"
        case .logs: return "chart.bar.doc.horizontal"
        }
    }
}

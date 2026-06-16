import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager
    @Binding var selectedRoute: AppRoute?
    @Environment(\.openWindow) private var openWindow
    private let sections = ["Main", "History", "Advanced"]

    var body: some View {
        List(selection: $selectedRoute) {
            ForEach(sections, id: \.self) { section in
                Section(section) {
                    ForEach(AppRoute.visibleRoutes.filter { $0.section == section }, id: \.self) { route in
                        NavigationLink(value: route) {
                            HStack(alignment: .center, spacing: 10) {
                                Image(systemName: route.systemImage)
                                    .foregroundColor(route == .rusToPrompt ? .blue : .secondary)
                                    .frame(width: 20)
                                Text(route.title)
                                    .font(.subheadline.weight(route == .rusToPrompt ? .semibold : .regular))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.92)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4)
                            .help(route.description)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
        .navigationSplitViewColumnWidth(240)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: { openWindow(id: "tests") }) {
                    Label("Open Tests", systemImage: "testtube.2")
                }
                .buttonStyle(.plain)
                .help("Open the test batch-runner in a separate window")
            }
            .padding()
        }
    }
}

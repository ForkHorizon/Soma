import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager
    @Binding var selectedRoute: AppRoute?
    @Environment(\.openWindow) private var openWindow
    @State private var projectsExpanded = true
    private let sections = ["Main", "History", "Advanced"]

    var body: some View {
        List(selection: $selectedRoute) {
            Section {
                DisclosureGroup(isExpanded: $projectsExpanded) {
                    if viewModel.recentProjectRoots.isEmpty {
                        Text("No projects added")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(viewModel.recentProjectRoots, id: \.self) { root in
                            Button {
                                viewModel.selectProjectRoot(root)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: root == viewModel.selectedProjectRoot ? "checkmark.circle.fill" : "folder")
                                        .foregroundColor(root == viewModel.selectedProjectRoot ? .blue : .secondary)
                                        .frame(width: 16)
                                    Text((root as NSString).lastPathComponent)
                                        .font(.caption.weight(root == viewModel.selectedProjectRoot ? .semibold : .regular))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 1)
                                .help(root)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button {
                        chooseProjectRoot()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.badge.plus")
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            Text("Choose Project...")
                                .font(.caption)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 1)
                    }
                    .buttonStyle(.plain)
                    .help("Add a project to the sidebar")
                } label: {
                    Label("Projects", systemImage: "folder")
                        .font(.subheadline.weight(.semibold))
                }
            }

            ForEach(sections, id: \.self) { section in
                Section(section) {
                    ForEach(AppRoute.visibleRoutes.filter { $0.section == section }, id: \.self) { route in
                        NavigationLink(value: route) {
                            HStack(alignment: .center, spacing: 10) {
                                Image(systemName: route.systemImage)
                                    .foregroundColor(route == .rusToPrompt ? .blue : .secondary)
                                    .frame(width: 18)
                                Text(route.title)
                                    .font(.subheadline.weight(route == selectedRoute ? .semibold : .regular))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.92)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                            .help(route.description)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 190, idealWidth: 215, maxWidth: 250)
        .navigationSplitViewColumnWidth(215)
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

    private func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Project Root"
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        viewModel.selectProjectRoot(path)
    }
}

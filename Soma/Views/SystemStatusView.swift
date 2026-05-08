import SwiftUI

struct SystemStatusView: View {
    @ObservedObject var viewModel: SomaViewModel
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("System Status")
                        .font(.largeTitle.bold())
                    Text("Versions and health of core Soma components")
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 8)
                
                // Components
                VStack(spacing: 16) {
                    statusCard(
                        title: "Graphify",
                        icon: "shareplay",
                        version: viewModel.graphifyVersion,
                        description: "Local-first knowledge graph and codebase analyzer.",
                        actionLabel: "Update Graphify",
                        isBusy: viewModel.systemBusy,
                        action: { viewModel.upgradeGraphify() }
                    )
                    
                    statusCard(
                        title: "Nexus Unity",
                        icon: "circle.grid.3x3.fill",
                        version: viewModel.nexusVersion,
                        description: "Bridge to Unity Editor and project-specific evidence.",
                        actionLabel: "Nexus connected via Editor",
                        isBusy: false,
                        isActionDisabled: true,
                        action: {}
                    )
                    
                    statusCard(
                        title: "Soma MCP Gateway",
                        icon: "server.rack.shell",
                        version: "v1.0.0 (Internal)",
                        description: "Unified entry point for AI clients (Codex, etc).",
                        actionLabel: "Integrated",
                        isBusy: false,
                        isActionDisabled: true,
                        action: {}
                    )
                }
                
                Spacer()
            }
            .padding(32)
            .frame(maxWidth: 800)
        }
        .onAppear {
            viewModel.fetchSystemVersions()
        }
    }
    
    private func statusCard(
        title: String,
        icon: String,
        version: String,
        description: String,
        actionLabel: String,
        isBusy: Bool,
        isActionDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(.blue)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Text(version)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                }
                
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)
                
                Button(action: action) {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(actionLabel)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isBusy || isActionDisabled)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }
}

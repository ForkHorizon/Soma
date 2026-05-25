import AppKit
import SwiftUI

enum SomaDesign {
    static let radius: CGFloat = 8
    static let pagePadding: CGFloat = 22
    static let panelSpacing: CGFloat = 14

    static var pageBackground: Color {
        Color(NSColor.textBackgroundColor).opacity(0.42)
    }

    static var panelBackground: Color {
        Color(NSColor.controlBackgroundColor).opacity(0.86)
    }

    static var elevatedBackground: Color {
        Color(NSColor.textBackgroundColor).opacity(0.78)
    }
}

enum SomaStatusTone: Equatable {
    case neutral
    case good
    case warning
    case danger
    case info

    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .good: return .green
        case .warning: return .orange
        case .danger: return .red
        case .info: return .blue
        }
    }

    var symbol: String {
        switch self {
        case .neutral: return "circle"
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }
}

struct WorkflowStep: Identifiable {
    let id: String
    let title: String
    let detail: String
    let tone: SomaStatusTone
}

struct WorkflowHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    var tone: SomaStatusTone = .info
    var trailing: AnyView?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(tone.color)
                .frame(width: 34, height: 34)
                .background(tone.color.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            if let trailing {
                trailing
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StepChecklist: View {
    let steps: [WorkflowStep]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
            ForEach(steps) { step in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: step.tone.symbol)
                            .foregroundColor(step.tone.color)
                            .font(.system(size: 12, weight: .semibold))
                        Text(step.title)
                            .font(.caption.bold())
                            .lineLimit(1)
                    }
                    Text(step.detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                .background(SomaDesign.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
                .overlay(RoundedRectangle(cornerRadius: SomaDesign.radius).stroke(step.tone.color.opacity(0.18)))
            }
        }
    }
}

struct StatusBanner: View {
    let title: String
    let detail: String
    let tone: SomaStatusTone
    var isLoading = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
            } else {
                Image(systemName: tone.symbol)
                    .foregroundColor(tone.color)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(12)
        .background(tone.color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
        .overlay(RoundedRectangle(cornerRadius: SomaDesign.radius).stroke(tone.color.opacity(0.20)))
    }
}

struct StatusChip: View {
    let text: String
    var tone: SomaStatusTone = .neutral
    var icon: String?

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.caption2.bold())
        .foregroundColor(tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tone.color.opacity(0.10))
        .clipShape(Capsule())
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let detail: String
    var tone: SomaStatusTone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.title3, design: .monospaced).bold())
                .foregroundColor(tone.color)
                .lineLimit(1)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .background(SomaDesign.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
        .overlay(RoundedRectangle(cornerRadius: SomaDesign.radius).stroke(tone.color.opacity(0.14)))
    }
}

struct PromptInputBar: View {
    @Binding var text: String
    let placeholder: String
    let buttonLabel: String
    let icon: String
    var disabled = false
    var disabledReason: String?
    var minHeight: CGFloat = 56
    var onClear: (() -> Void)?
    let action: () -> Void

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var actionDisabled: Bool {
        disabled || trimmedText.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundColor(.secondary)
                        .padding(.leading, 8)
                        .padding(.top, 9)
                        .font(.body)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: minHeight, idealHeight: minHeight, maxHeight: minHeight + 24)
                    .padding(4)
                    .background(Color.clear)
                    .accessibilityLabel(Text(placeholder))
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.20)))

            HStack(spacing: 10) {
                if let onClear {
                    Button("Clear", action: onClear)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if let disabledReason, disabled {
                    Label(disabledReason, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if trimmedText.isEmpty {
                    Text("Describe the task to continue.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: action) {
                    HStack(spacing: 6) {
                        Image(systemName: icon)
                        Text(buttonLabel)
                    }
                    .bold()
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(actionDisabled)
                .keyboardShortcut(.return, modifiers: .command)
                .help(actionDisabled ? (disabledReason ?? "Enter a prompt to continue") : "Submit (Command-Return)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider(), alignment: .top)
    }
}

struct SomaPage<Content: View>: View {
    var maxWidth: CGFloat = 1320
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SomaDesign.panelSpacing) {
                content()
            }
            .padding(SomaDesign.pagePadding)
            .frame(maxWidth: maxWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(SomaDesign.pageBackground)
    }
}

struct SomaPanel<Content: View>: View {
    let title: String
    var subtitle: String?
    var icon: String?
    var tone: SomaStatusTone = .neutral
    var trailing: AnyView?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 9) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(tone.color)
                        .frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 10)
                if let trailing {
                    trailing
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
        .overlay(RoundedRectangle(cornerRadius: SomaDesign.radius).stroke(Color.secondary.opacity(0.12)))
    }
}

struct SomaSplitWorkbench<Primary: View, Secondary: View>: View {
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                primary()
            }
            .frame(minWidth: 520, maxWidth: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 14) {
                secondary()
            }
            .frame(width: 320, alignment: .topLeading)
        }
    }
}

struct SomaKeyValueRow: View {
    let label: String
    let value: String
    var tone: SomaStatusTone = .neutral

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundColor(tone.color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}

struct EvidenceRow: View {
    let item: EvidenceItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                StatusChip(text: item.kind?.uppercased() ?? "FILE", tone: .neutral)
                Text(URL(fileURLWithPath: item.path ?? "").lastPathComponent)
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer()
                if let startLine = item.start_line {
                    Text("Lines \(startLine)\(item.end_line.map { "-\($0)" } ?? "")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Text(item.path ?? "")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
            if let reason = item.reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let symbols = item.symbols, !symbols.isEmpty {
                Text("Symbols: \(symbols.prefix(8).joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            if let preview = item.preview, !preview.isEmpty {
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SomaDesign.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
        .overlay(RoundedRectangle(cornerRadius: SomaDesign.radius).stroke(Color.secondary.opacity(0.12)))
    }
}

struct ActivityLogPanel: View {
    let logs: [String]
    @Binding var isExpanded: Bool

    var body: some View {
        if !logs.isEmpty {
            DetailDisclosure(
                title: "Activity Log",
                subtitle: "\(logs.count) runtime messages from this run",
                icon: "list.bullet.clipboard",
                isExpanded: $isExpanded,
                trailing: AnyView(
                    Button {
                        copyToClipboard(logs.joined(separator: "\n"))
                    } label: {
                        Label("Copy Log", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                )
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(logs, id: \.self) { log in
                        Text(log)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .background(SomaDesign.elevatedBackground)
                .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
            }
        }
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var actionTitle: String?
    var actionIcon: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 48)
            Image(systemName: icon)
                .font(.system(size: 42))
                .foregroundColor(.secondary.opacity(0.45))
            Text(title)
                .font(.title3.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: actionIcon ?? "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 2)
            }
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

struct DetailDisclosure<Content: View>: View {
    let title: String
    let subtitle: String?
    let icon: String
    @Binding var isExpanded: Bool
    var trailing: AnyView?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: icon)
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.bold())
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    if let trailing {
                        trailing
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
            }
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
        .overlay(RoundedRectangle(cornerRadius: SomaDesign.radius).stroke(Color.secondary.opacity(0.12)))
    }
}

func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

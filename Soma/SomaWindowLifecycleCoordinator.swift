import AppKit
import Combine
import SwiftUI

/// Switches Soma between its regular Dock presentation and its hidden,
/// menu-bar-only presentation without destroying the main SwiftUI window.
@MainActor
final class SomaWindowLifecycleCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    private weak var mainWindow: NSWindow?
    private weak var globalVoice: GlobalVoiceController?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var originalWindowDelegate: NSWindowDelegate?
    @Published private var isHiddenInMenuBar = false

    func attach(mainWindow: NSWindow?, globalVoice: GlobalVoiceController) {
        guard let mainWindow else { return }

        self.globalVoice = globalVoice
        guard self.mainWindow !== mainWindow else { return }

        if let previousWindow = self.mainWindow,
           (previousWindow.delegate as AnyObject?) === self {
            previousWindow.delegate = originalWindowDelegate
        }

        self.mainWindow = mainWindow
        originalWindowDelegate = mainWindow.delegate
        mainWindow.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow else { return true }
        guard originalWindowDelegate?.windowShouldClose?(sender) ?? true else { return false }
        hideMainWindow()
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || originalWindowDelegate?.responds(to: aSelector) == true
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        guard !super.responds(to: aSelector),
              originalWindowDelegate?.responds(to: aSelector) == true else {
            return super.forwardingTarget(for: aSelector)
        }
        return originalWindowDelegate
    }

    private func hideMainWindow() {
        guard !isHiddenInMenuBar else { return }

        isHiddenInMenuBar = true
        mainWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        showStatusItem()
    }

    private func showStatusItem() {
        guard statusItem == nil, let globalVoice else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }

        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Soma")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Soma voice controls"
        button.target = self
        button.action = #selector(togglePopover(_:))

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 220)
        popover.contentViewController = NSHostingController(
            rootView: SomaMenuBarPopover(
                globalVoice: globalVoice,
                openSoma: { [weak self] in self?.openMainWindow() },
                quitSoma: { NSApp.terminate(nil) }
            )
        )

        statusItem = item
        self.popover = popover
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func openMainWindow() {
        popover?.performClose(nil)
        popover = nil

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }

        isHiddenInMenuBar = false
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func handleApplicationReopen() -> Bool {
        guard isHiddenInMenuBar else { return false }
        openMainWindow()
        return true
    }
}

@MainActor
private struct SomaMenuBarPopover: View {
    @ObservedObject var globalVoice: GlobalVoiceController
    @AppStorage("globalVoicePasteEnabled") private var globalVoicePasteEnabled = false

    let openSoma: () -> Void
    let quitSoma: () -> Void

    private var voiceEnabled: Binding<Bool> {
        Binding(
            get: { globalVoicePasteEnabled },
            set: { enabled in
                globalVoicePasteEnabled = enabled
                globalVoice.setEnabled(enabled, promptForPermission: enabled)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Soma Voice Input")
                .font(.headline)

            Toggle("Global Right Command paste", isOn: voiceEnabled)

            Text(globalVoice.status)
                .font(.caption)
                .foregroundStyle(globalVoice.needsAccessibilityPermission ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            if globalVoice.needsAccessibilityPermission {
                Button("Open Accessibility Settings") {
                    globalVoice.openAccessibilitySettings()
                }
            }

            Divider()

            HStack {
                Button("Open Soma", action: openSoma)
                Spacer()
                Button("Quit Soma", role: .destructive, action: quitSoma)
            }
        }
        .padding()
        .frame(width: 300, alignment: .leading)
    }
}

@MainActor
final class SomaAppDelegate: NSObject, NSApplicationDelegate {
    weak var windowLifecycle: SomaWindowLifecycleCoordinator?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowLifecycle?.handleApplicationReopen() ?? false
    }
}

struct MainWindowAccessor: NSViewRepresentable {
    let onWindowReady: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            onWindowReady(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onWindowReady(nsView.window)
        }
    }
}

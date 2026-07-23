import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class GlobalVoiceController: ObservableObject {
    @Published var status = "Global Right Command paste is off."
    @Published var needsAccessibilityPermission = false

    private weak var asr: ASRManager?
    private weak var somaViewModel: SomaViewModel?
    private weak var ollama: OllamaManager?
    private weak var prompter: RusToPromptViewModel?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var holdTask: Task<Void, Never>?
    private var pasteTask: Task<Void, Never>?
    private var rightCommandDown = false
    private var comboUsed = false
    private var recording = false
    private var targetApplication: NSRunningApplication?
    private let overlay = GlobalVoiceOverlay()

    private let rightCommandKeyCode = 54
    private let escapeKeyCode = 53
    private let pasteKeyCode: CGKeyCode = 9

    func configure(asr: ASRManager, somaViewModel: SomaViewModel, ollama: OllamaManager, prompter: RusToPromptViewModel) {
        self.asr = asr
        self.somaViewModel = somaViewModel
        self.ollama = ollama
        self.prompter = prompter
    }

    func setEnabled(_ enabled: Bool, promptForPermission: Bool = false) {
        if enabled {
            guard accessibilityTrusted(prompt: promptForPermission) else {
                needsAccessibilityPermission = true
                stopEventTap()
                show("Allow Accessibility access to use Right Command paste.", image: "lock.shield")
                return
            }
            needsAccessibilityPermission = false
            startEventTap()
        } else {
            stopEventTap()
            status = "Global Right Command paste is off."
        }
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func accessibilityTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func startEventTap() {
        guard eventTap == nil else {
            status = "Hold Right Command to record, release to paste."
            return
        }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<GlobalVoiceController>.fromOpaque(refcon).takeUnretainedValue()
                let rawType = type.rawValue
                let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
                Task { @MainActor in
                    controller.handleTapEvent(rawType: rawType, keyCode: keyCode)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            needsAccessibilityPermission = true
            show("Could not start Right Command listener. Check Accessibility access.", image: "exclamationmark.triangle")
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        overlay.prepare()
        status = "Hold Right Command to record, release to paste."
    }

    private func stopEventTap() {
        holdTask?.cancel()
        holdTask = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        eventTap = nil
        rightCommandDown = false
        comboUsed = false
    }

    private func handleTapEvent(rawType: UInt32, keyCode: Int) {
        if rawType == CGEventType.tapDisabledByTimeout.rawValue || rawType == CGEventType.tapDisabledByUserInput.rawValue {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        if rawType == CGEventType.flagsChanged.rawValue, keyCode == rightCommandKeyCode {
            rightCommandDown ? rightCommandUp() : rightCommandDownEvent()
            return
        }
        guard rawType == CGEventType.keyDown.rawValue else { return }
        if keyCode == escapeKeyCode, rightCommandDown {
            cancel()
        } else if rightCommandDown, !recording {
            comboUsed = true
            holdTask?.cancel()
            holdTask = nil
        }
    }

    private func rightCommandDownEvent() {
        guard eventTap != nil, asr?.isRecording != true, asr?.isTranscribing != true else { return }
        rightCommandDown = true
        comboUsed = false
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            await MainActor.run { self?.startRecordingIfStillHeld() }
        }
    }

    private func rightCommandUp() {
        rightCommandDown = false
        holdTask?.cancel()
        holdTask = nil
        guard recording else { return }
        recording = false
        finishAndPaste()
    }

    private func startRecordingIfStillHeld() {
        guard rightCommandDown, !comboUsed, !recording else { return }
        guard let asr, !asr.isRecording, !asr.isTranscribing else { return }
        targetApplication = NSWorkspace.shared.frontmostApplication
        recording = true
        show("Recording", image: "mic.fill", busy: false)
        asr.startGlobalRecording()
    }

    private func finishAndPaste() {
        pasteTask?.cancel()
        pasteTask = Task { [weak self] in
            guard let self else { return }
            show("Transcribing", image: "waveform", busy: true)
            let rawText = await asr?.stopGlobalRecording()
            guard let text = rawText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                show("No speech", image: "mic.slash")
                overlay.hide(after: 1.4)
                return
            }
            do {
                let output = try await outputText(for: text)
                guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    show("Nothing to paste.", image: "doc")
                    overlay.hide(after: 1.4)
                    return
                }
                show("Pasting", image: "doc.on.clipboard", busy: true)
                await paste(output, into: targetApplication)
                show("Pasted.", image: "checkmark.circle.fill")
                overlay.hide(after: 1.0)
            } catch {
                show(error.localizedDescription, image: "exclamationmark.triangle")
            }
        }
    }

    private func cancel() {
        holdTask?.cancel()
        holdTask = nil
        rightCommandDown = false
        comboUsed = false
        recording = false
        asr?.cancelRecording()
        show("Canceled", image: "xmark.circle")
        overlay.hide(after: 1.0)
    }

    private func outputText(for text: String) async throws -> String {
        let mode = UserDefaults.standard.string(forKey: "voiceMode") ?? "prompt"
        guard mode != "text" else { return text }
        guard let somaViewModel, let ollama, let prompter else { return text }

        prompter.inputPrompt = text
        prompter.resetRunState()
        prompter.phase = .translating
        show("Translating", image: "character.book.closed", busy: true)
        let translated = try await somaViewModel.runRusToPromptTranslate(prompt: text, translatorModel: prompter.translatorModel)
        let translatedText = translated.translation ?? ""
        guard await prompter.applyTranslationResult(translated, translatedText: translatedText, ollama: ollama) else {
            throw SomaError(prompter.errorMessage ?? "Translation failed.")
        }
        if mode == "translate" {
            prompter.phase = .done
            ollama.checkStatus()
            return translatedText
        }

        prompter.phase = .analyzing
        show("Building prompt", image: "wand.and.stars", busy: true)
        let improved = try await somaViewModel.runRusToPromptImprove(prompt: translatedText, analyzerModel: prompter.analyzerModel)
        await prompter.applyImprovementResult(improved, sourcePrompt: text, ollama: ollama, queueManager: nil)
        return prompter.finalPromptForCopy
    }

    private func paste(_ text: String, into app: NSRunningApplication?) async {
        let pasteboard = NSPasteboard.general
        let oldItems = snapshotClipboard(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let pasteChangeCount = pasteboard.changeCount

        app?.activate(options: [])
        try? await Task.sleep(nanoseconds: 140_000_000)
        sendCommandV()
        try? await Task.sleep(nanoseconds: 700_000_000)

        guard pasteboard.changeCount == pasteChangeCount else { return }
        pasteboard.clearContents()
        if let oldItems, !oldItems.isEmpty {
            pasteboard.writeObjects(oldItems)
        }
    }

    private func snapshotClipboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func sendCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func show(_ message: String, image: String, busy: Bool = false) {
        status = message
        overlay.show(message: message, image: image, busy: busy)
    }
}

@MainActor
private final class OverlayModel: ObservableObject {
    @Published var message = ""
    @Published var image = "mic.fill"
    @Published var busy = false
    @Published var expanded = false
    @Published var hasNotch = true
    @Published var notchWidth: CGFloat = 180
    @Published var notchHeight: CGFloat = 32

    func update(message: String, image: String, busy: Bool) {
        withAnimation(.easeInOut(duration: 0.16)) {
            self.message = message
            self.image = image
            self.busy = busy
        }
    }
}

@MainActor
private final class GlobalVoiceOverlay {
    private var window: NSPanel?
    private let model = OverlayModel()
    private var hideWork: DispatchWorkItem?

    /// Create the window up front so the first hold paints immediately.
    func prepare() {
        ensureWindow()
        layout()
    }

    func show(message: String, image: String, busy: Bool) {
        hideWork?.cancel()
        let firstReveal = !model.expanded
        ensureWindow()
        layout()
        window?.orderFrontRegardless()
        window?.displayIfNeeded()
        model.update(message: message, image: image, busy: busy)
        if firstReveal {
            model.expanded = false            // render collapsed baseline first…
            DispatchQueue.main.async { [weak self] in
                self?.model.expanded = true   // …then spring open (animated by the view)
            }
        }
    }

    func hide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                self.model.expanded = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { self.window?.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 96), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentViewController = NSHostingController(rootView: DynamicIslandView(model: model))
        window = panel
    }

    /// Read the current screen's notch geometry and park the panel flush to the top-center.
    private func layout() {
        guard let screen = NSScreen.main, let window else { return }
        let inset = screen.safeAreaInsets.top
        model.hasNotch = inset > 0
        model.notchHeight = inset
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, r.minX > l.maxX {
            model.notchWidth = r.minX - l.maxX          // real notch (camera) width
        } else {
            model.notchWidth = 180                       // no notch: floating top pill
        }
        let full = screen.frame
        let size = window.frame.size
        // Notch Macs: flush to the top bezel so it merges with the camera cutout.
        // No-notch Macs: drop just below the menu bar as a floating pill.
        let topEdge = model.hasNotch ? full.maxY : screen.visibleFrame.maxY - 6
        window.setFrameOrigin(NSPoint(x: full.midX - size.width / 2, y: topEdge - size.height))
    }
}

/// A rounded-bottom, square-top shape so the top edge sits flush with the screen bezel
/// and the body drops out of the camera notch like Dynamic Island.
private struct NotchIsland: Shape {
    var topRadius: CGFloat = 0      // 0 = square top (flush to notch); >0 = rounded pill
    var bottomRadius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let tr = topRadius, br = bottomRadius
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + tr))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + tr), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - br, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + br, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - br), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct IslandWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A dark, notch-merging surface with continuous "liquid" motion: a colored glow drifts
/// inside it and a specular highlight travels along the top edge, so it reads as living
/// glass even on a black wallpaper where real refraction has nothing to sample.
private struct LiquidGlassSurface: View {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var tint: Color

    var body: some View {
        let shape = NotchIsland(topRadius: topRadius, bottomRadius: bottomRadius)
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let drift = CGFloat(sin(t * 0.9))            // slow left/right sweep, -1…1
            let bob = CGFloat(sin(t * 1.3 + 1))          // gentle vertical shimmer
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    shape.fill(Color(white: 0.035))
                    // living colored core the glass refracts
                    RadialGradient(colors: [tint.opacity(0.55), tint.opacity(0.12), .clear],
                                   center: .center, startRadius: 0, endRadius: w * 0.55)
                        .frame(width: w * 1.1, height: h * 2.0)
                        .position(x: w * 0.5 + drift * w * 0.26, y: h * 0.8 + bob * h * 0.12)
                        .blur(radius: 16)
                    // static top sheen (the glass dome)
                    shape.fill(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.03), .clear],
                                              startPoint: .top, endPoint: .bottom))
                    // specular highlight sliding along the top edge
                    Capsule().fill(.white.opacity(0.5))
                        .frame(width: w * 0.42, height: 2.5)
                        .blur(radius: 3)
                        .position(x: w * 0.5 + drift * w * 0.32, y: 3.5)
                    // rim light
                    shape.stroke(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.04)],
                                                startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
                }
                .clipShape(shape)
            }
        }
    }
}

private struct DynamicIslandView: View {
    @ObservedObject var model: OverlayModel
    @State private var contentWidth: CGFloat = 0

    private var iconColor: Color {
        switch model.image {
        case "mic.fill": return .red
        case "checkmark.circle.fill": return .green
        case "mic.slash", "xmark.circle", "exclamationmark.triangle", "lock.shield": return .orange
        default: return .white.opacity(0.85)
        }
    }

    // Expanded island hugs its content; collapsed it matches the notch so it disappears into it.
    private var islandWidth: CGFloat {
        model.expanded ? max(contentWidth, model.notchWidth) : model.notchWidth
    }
    private var islandHeight: CGFloat {
        model.expanded ? model.notchHeight + 42 : model.notchHeight
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            content
                .fixedSize()
                .background(GeometryReader { g in
                    Color.clear.preference(key: IslandWidthKey.self, value: g.size.width)
                })
                .frame(width: islandWidth, height: islandHeight, alignment: .bottom)
                .background(islandSurface)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
                .animation(.spring(response: 0.4, dampingFraction: 0.74), value: islandWidth)
                .animation(.spring(response: 0.4, dampingFraction: 0.74), value: islandHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(IslandWidthKey.self) { contentWidth = $0 }
    }

    // The glow color that lives *inside* the glass. On a black wallpaper the real
    // .glassEffect has nothing to refract, so we give the glass a moving colored core.
    private var glowTint: Color {
        if model.busy { return Color(red: 0.35, green: 0.55, blue: 1.0) }   // cool blue while working
        switch model.image {
        case "mic.fill": return .red
        case "checkmark.circle.fill": return .green
        case "mic.slash", "xmark.circle", "exclamationmark.triangle", "lock.shield": return .orange
        default: return Color(red: 0.35, green: 0.55, blue: 1.0)
        }
    }

    private var islandSurface: some View {
        let r: CGFloat = model.expanded ? 22 : 10
        return LiquidGlassSurface(topRadius: model.hasNotch ? 0 : r, bottomRadius: r, tint: glowTint)
    }

    private var content: some View {
        HStack(spacing: 8) {
            ZStack {
                if model.busy {
                    ProgressView().controlSize(.small).tint(.white.opacity(0.75))
                } else {
                    Image(systemName: model.image)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 16, height: 16)
            Text(model.message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 11)
        .opacity(model.expanded ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: model.expanded)
    }
}

import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import SwiftUI

enum VoiceOutputMode: String, CaseIterable {
    case original = "text"
    case english = "translate"
    case prompt

    static let storageKey = "voiceMode"

    static var current: VoiceOutputMode {
        VoiceOutputMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .prompt
    }

    static func persist(_ mode: VoiceOutputMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: storageKey)
    }

    nonisolated static func mode(forKeyCode keyCode: Int) -> VoiceOutputMode? {
        switch keyCode {
        case 18, 83: return .original // 1, keypad 1
        case 19, 84: return .english  // 2, keypad 2
        case 20, 85: return .prompt   // 3, keypad 3
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .original: "Original"
        case .english: "English"
        case .prompt: "Prompt"
        }
    }

    var hint: String {
        switch self {
        case .original: "Speech recognition only. Run translate or prompt manually with the buttons below."
        case .english: "After recognition, the text is translated to English. No prompt step."
        case .prompt: "After recognition: translate → polished English prompt."
        }
    }

    var icon: String {
        switch self {
        case .original: "text.quote"
        case .english: "character.book.closed"
        case .prompt: "wand.and.stars"
        }
    }

    var shortcut: Int {
        switch self {
        case .original: 1
        case .english: 2
        case .prompt: 3
        }
    }

    var tint: Color {
        switch self {
        case .original: Color(red: 0.28, green: 0.88, blue: 0.68)
        case .english: Color(red: 0.32, green: 0.63, blue: 1.0)
        case .prompt: Color(red: 0.74, green: 0.46, blue: 1.0)
        }
    }
}

/// Keeps the minimal state needed to synchronously swallow mode keys in the
/// event-tap callback before the foreground app can see them.
nonisolated final class RightCommandModeKeyCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var rightCommandDown = false

    func toggleRightCommand() {
        lock.lock()
        rightCommandDown.toggle()
        lock.unlock()
    }

    func setRightCommandDown(_ isDown: Bool) {
        lock.lock()
        rightCommandDown = isDown
        lock.unlock()
    }

    func shouldConsume(type: CGEventType, keyCode: Int) -> Bool {
        guard type == .keyDown || type == .keyUp, VoiceOutputMode.mode(forKeyCode: keyCode) != nil else { return false }
        lock.lock()
        defer { lock.unlock() }
        return rightCommandDown
    }
}

private enum GlobalVoiceJobPhase: String {
    case queued = "Queued"
    case transcribing = "Transcribing"
    case translating = "Translating"
    case buildingPrompt = "Building prompt"
    case pasting = "Pasting"
}

private struct GlobalVoiceJob: Identifiable {
    let id = UUID()
    let recording: CapturedVoiceRecording
    let mode: VoiceOutputMode
    let targetApplication: NSRunningApplication?
    var phase: GlobalVoiceJobPhase = .queued
}

private struct GlobalVoiceQueueItem: Identifiable {
    let id: UUID
    let title: String
    let detail: String
    let isActive: Bool
}

struct GlobalVoiceFIFO<Element> {
    private(set) var elements: [Element] = []

    var isEmpty: Bool { elements.isEmpty }
    var count: Int { elements.count }

    mutating func enqueue(_ element: Element) {
        elements.append(element)
    }

    mutating func dequeue() -> Element? {
        guard !elements.isEmpty else { return nil }
        return elements.removeFirst()
    }
}

@MainActor
final class GlobalVoiceController: ObservableObject {
    @Published var status = "Global Right Command paste is off."
    @Published var needsAccessibilityPermission = false

    private weak var asr: ASRManager?
    private weak var somaViewModel: SomaViewModel?
    private weak var ollama: OllamaManager?
    private weak var prompter: RusToPromptViewModel?
    private weak var textPriorityQueue: VoiceTextPriorityQueue?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var holdTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var permissionRetryTask: Task<Void, Never>?
    private var audioLevelCancellable: AnyCancellable?
    private var rightCommandDown = false
    private var comboUsed = false
    private var recording = false
    private var recordingMode: VoiceOutputMode = .current
    private var recordingTargetApplication: NSRunningApplication?
    private var activeJob: GlobalVoiceJob?
    private var queuedJobs = GlobalVoiceFIFO<GlobalVoiceJob>()
    private let overlay = GlobalVoiceOverlay()
    nonisolated private let keyCapture = RightCommandModeKeyCapture()

    private let rightCommandKeyCode = 54
    private let escapeKeyCode = 53
    private let pasteKeyCode: CGKeyCode = 9

    func configure(asr: ASRManager, somaViewModel: SomaViewModel, ollama: OllamaManager, prompter: RusToPromptViewModel, textPriorityQueue: VoiceTextPriorityQueue) {
        self.asr = asr
        self.somaViewModel = somaViewModel
        self.ollama = ollama
        self.prompter = prompter
        self.textPriorityQueue = textPriorityQueue
        audioLevelCancellable = asr.$inputLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                guard let self else { return }
                overlay.updateAudioLevel(recording ? level : 0)
            }
    }

    func setEnabled(_ enabled: Bool, promptForPermission: Bool = false) {
        if enabled {
            guard accessibilityTrusted(prompt: promptForPermission) else {
                needsAccessibilityPermission = true
                stopEventTap()
                startPermissionRetry()
                show("Allow Accessibility access to use Right Command paste.", image: "lock.shield")
                return
            }
            stopPermissionRetry()
            needsAccessibilityPermission = false
            startEventTap()
        } else {
            stopPermissionRetry()
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

    private func startPermissionRetry() {
        guard permissionRetryTask == nil else { return }
        permissionRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                let done = await MainActor.run { [weak self] in
                    guard let self else { return true }
                    guard self.accessibilityTrusted(prompt: false) else { return false }
                    self.needsAccessibilityPermission = false
                    self.startEventTap()
                    if self.eventTap != nil {
                        self.permissionRetryTask = nil
                        return true
                    }
                    return false
                }
                if done { return }
            }
        }
    }

    private func stopPermissionRetry() {
        permissionRetryTask?.cancel()
        permissionRetryTask = nil
    }

    private func startEventTap() {
        guard eventTap == nil else {
            status = "Hold Right Command to record, release to paste."
            return
        }
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
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
                let consumeEvent = controller.captureEvent(type: type, keyCode: keyCode)
                Task { @MainActor in
                    controller.handleTapEvent(rawType: rawType, keyCode: keyCode, modeKeyWasCaptured: consumeEvent)
                }
                return consumeEvent ? nil : Unmanaged.passUnretained(event)
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
        if recording || asr?.isRecording == true {
            cancel()
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        eventTap = nil
        keyCapture.setRightCommandDown(false)
        rightCommandDown = false
        comboUsed = false
    }

    nonisolated private func captureEvent(type: CGEventType, keyCode: Int) -> Bool {
        if type == .flagsChanged, keyCode == 54 {
            keyCapture.toggleRightCommand()
            return false
        }
        return keyCapture.shouldConsume(type: type, keyCode: keyCode)
    }

    private func handleTapEvent(rawType: UInt32, keyCode: Int, modeKeyWasCaptured: Bool) {
        if rawType == CGEventType.tapDisabledByTimeout.rawValue || rawType == CGEventType.tapDisabledByUserInput.rawValue {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        if rawType == CGEventType.flagsChanged.rawValue, keyCode == rightCommandKeyCode {
            rightCommandDown ? rightCommandUp() : rightCommandDownEvent()
            return
        }
        guard rawType == CGEventType.keyDown.rawValue else { return }
        if modeKeyWasCaptured, let mode = VoiceOutputMode.mode(forKeyCode: keyCode) {
            selectOutputMode(mode)
        } else if keyCode == escapeKeyCode, rightCommandDown {
            cancel()
        } else if rightCommandDown, !recording {
            comboUsed = true
            holdTask?.cancel()
            holdTask = nil
        }
    }

    private func rightCommandDownEvent() {
        guard eventTap != nil, asr?.isRecording != true else { return }
        rightCommandDown = true
        comboUsed = false
        recordingMode = .current
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
        finishAndPaste(using: recordingMode)
    }

    private func startRecordingIfStillHeld() {
        guard rightCommandDown, !comboUsed, !recording else { return }
        guard let asr, !asr.isRecording else { return }
        recordingTargetApplication = NSWorkspace.shared.frontmostApplication
        recording = true
        refreshOverlay()
        asr.startGlobalRecording()
    }

    private func selectOutputMode(_ mode: VoiceOutputMode) {
        VoiceOutputMode.persist(mode)
        recordingMode = mode
        let state = recording ? "Recording" : "Ready"
        show("\(state) · \(mode.title)", image: "mic.fill", busy: false, mode: mode, showsModeSelector: true)
    }

    private func finishAndPaste(using mode: VoiceOutputMode) {
        captureTask = Task { [weak self] in
            guard let self else { return }
            guard let recording = await asr?.finishGlobalRecording() else {
                captureTask = nil
                refreshOverlay(message: asr?.status ?? "No speech", image: "mic.slash")
                if !self.recording { overlay.hide(after: 1.4) }
                return
            }
            queuedJobs.enqueue(GlobalVoiceJob(
                recording: recording,
                mode: mode,
                targetApplication: recordingTargetApplication
            ))
            recordingTargetApplication = nil
            captureTask = nil
            startNextQueuedJob()
        }
    }

    private func startNextQueuedJob() {
        guard activeJob == nil, !queuedJobs.isEmpty else {
            refreshOverlay()
            return
        }
        guard var job = queuedJobs.dequeue() else { return }
        job.phase = .transcribing
        activeJob = job
        refreshOverlay()

        queueTask = Task { [weak self] in
            guard let self else { return }
            let transcriptionStartedAt = Date()
            let rawText = await asr?.transcribeGlobalRecording(job.recording)
            guard let text = rawText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                finishActiveJob(message: asr?.status ?? "No speech", image: "mic.slash")
                return
            }
            VoiceMetrics.log("global_final_asr", [
                "release_to_final_milliseconds": "\(Int(Date().timeIntervalSince(transcriptionStartedAt) * 1_000))",
            ])

            do {
                updateActiveJob(job.id, phase: job.mode == .original ? .pasting : .translating)
                let output = try await outputText(for: text, mode: job.mode) { [weak self] phase in
                    self?.updateActiveJob(job.id, phase: phase)
                }
                guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    finishActiveJob(message: "Nothing to paste.", image: "doc")
                    return
                }
                updateActiveJob(job.id, phase: .pasting)
                await paste(output, into: job.targetApplication)
                finishActiveJob(message: "Pasted.", image: "checkmark.circle.fill")
            } catch {
                finishActiveJob(message: error.localizedDescription, image: "exclamationmark.triangle")
            }
        }
    }

    private func updateActiveJob(_ id: UUID, phase: GlobalVoiceJobPhase) {
        guard var job = activeJob, job.id == id else { return }
        job.phase = phase
        activeJob = job
        refreshOverlay()
    }

    private func finishActiveJob(message: String, image: String) {
        activeJob = nil
        queueTask = nil
        refreshOverlay(message: message, image: image)
        if queuedJobs.isEmpty, !recording {
            overlay.hide(after: 1.0)
        } else {
            startNextQueuedJob()
        }
    }

    private func refreshOverlay(message: String? = nil, image: String? = nil) {
        overlay.updateQueue(queueItems)
        if recording {
            show("Recording · \(recordingMode.title)", image: "mic.fill", busy: false, mode: recordingMode, showsModeSelector: true)
        } else if let message, let image {
            show(message, image: image, busy: false)
        } else if let activeJob {
            show(activeJob.phase.rawValue, image: activeJob.phase == .pasting ? "doc.on.clipboard" : "waveform", busy: true, mode: activeJob.mode)
        } else if !queuedJobs.isEmpty {
            show("\(queuedJobs.count) recording\(queuedJobs.count == 1 ? "" : "s") queued", image: "clock", busy: true)
        }
    }

    private var queueItems: [GlobalVoiceQueueItem] {
        var items: [GlobalVoiceQueueItem] = []
        if let activeJob {
            items.append(GlobalVoiceQueueItem(
                id: activeJob.id,
                title: "Now · \(activeJob.mode.title)",
                detail: activeJob.phase.rawValue,
                isActive: true
            ))
        }
        items.append(contentsOf: queuedJobs.elements.enumerated().map { index, job in
            GlobalVoiceQueueItem(
                id: job.id,
                title: "Next \(index + 1) · \(job.mode.title)",
                detail: GlobalVoiceJobPhase.queued.rawValue,
                isActive: false
            )
        })
        return items
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

    private func outputText(
        for text: String,
        mode: VoiceOutputMode,
        updatePhase: @escaping (GlobalVoiceJobPhase) -> Void
    ) async throws -> String {
        guard mode != .original else {
            VoiceMetrics.log("voice_output_finished", ["mode": "text", "duration_milliseconds": "0"])
            return text
        }
        if let textPriorityQueue {
            let output = try await textPriorityQueue.translateInteractive(text, mode: mode) { [weak self] phase in
                guard self != nil else { return }
                updatePhase(phase == .buildingPrompt ? .buildingPrompt : .translating)
            }
            return output
        }
        guard let somaViewModel, let ollama, let prompter else { return text }

        prompter.inputPrompt = text
        prompter.resetRunState()
        prompter.phase = .translating
        updatePhase(.translating)
        let translationStartedAt = Date()
        let translated = try await somaViewModel.runRusToPromptTranslate(prompt: text, translatorModel: prompter.translatorModel)
        let translatedText = translated.translation ?? ""
        guard await prompter.applyTranslationResult(translated, translatedText: translatedText, ollama: ollama) else {
            throw SomaError(prompter.errorMessage ?? "Translation failed.")
        }
        VoiceMetrics.log("translation_finished", [
            "duration_milliseconds": "\(Int(Date().timeIntervalSince(translationStartedAt) * 1_000))",
        ])
        if mode == .english {
            prompter.phase = .done
            ollama.checkStatus()
            return translatedText
        }

        prompter.phase = .analyzing
        updatePhase(.buildingPrompt)
        let promptStartedAt = Date()
        let improved = try await somaViewModel.runRusToPromptImprove(prompt: translatedText, analyzerModel: prompter.analyzerModel)
        await prompter.applyImprovementResult(improved, sourcePrompt: text, ollama: ollama, queueManager: nil)
        VoiceMetrics.log("prompt_generation_finished", [
            "duration_milliseconds": "\(Int(Date().timeIntervalSince(promptStartedAt) * 1_000))",
        ])
        return prompter.finalPromptForCopy
    }

    private func paste(_ text: String, into app: NSRunningApplication?) async {
        let startedAt = Date()
        defer {
            VoiceMetrics.log("paste_finished", [
                "duration_milliseconds": "\(Int(Date().timeIntervalSince(startedAt) * 1_000))",
            ])
        }
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

    private func show(
        _ message: String,
        image: String,
        busy: Bool = false,
        mode: VoiceOutputMode? = nil,
        showsModeSelector: Bool = false
    ) {
        status = message
        overlay.show(
            message: message,
            image: image,
            busy: busy,
            mode: mode ?? recordingMode,
            showsModeSelector: showsModeSelector
        )
    }
}

@MainActor
private final class OverlayModel: ObservableObject {
    static let transition = Animation.spring(response: 0.68, dampingFraction: 0.86, blendDuration: 0.12)
    static let glowTransition = Animation.spring(response: 0.86, dampingFraction: 0.9, blendDuration: 0.18)

    @Published var message = ""
    @Published var image = "mic.fill"
    @Published var busy = false
    @Published var mode: VoiceOutputMode = .current
    @Published var showsModeSelector = false
    @Published var expanded = false
    @Published var hasNotch = true
    @Published var notchWidth: CGFloat = 180
    @Published var notchHeight: CGFloat = 32
    @Published var queueItems: [GlobalVoiceQueueItem] = []
    @Published var audioLevel: Double = 0

    func update(message: String, image: String, busy: Bool, mode: VoiceOutputMode, showsModeSelector: Bool) {
        let modePrefixes = ["Recording · ", "Ready · "]
        let isModeSwitch = self.showsModeSelector && showsModeSelector
            && self.image == image && self.busy == busy
            && modePrefixes.contains(where: {
                self.message.hasPrefix($0) && message.hasPrefix($0)
            })

        // A mode key is a lightweight selection, not a new island state. Avoid
        // restarting the large layout spring for every rapid 1/2/3 press.
        if isModeSwitch {
            self.message = message
            self.mode = mode
            return
        }

        withAnimation(Self.transition) {
            self.message = message
            self.image = image
            self.busy = busy
            self.mode = mode
            self.showsModeSelector = showsModeSelector
        }
    }

    func updateQueue(_ items: [GlobalVoiceQueueItem]) {
        withAnimation(Self.transition) {
            queueItems = items
        }
    }

    func updateAudioLevel(_ level: Double) {
        audioLevel = min(max(level, 0), 1)
    }
}

@MainActor
private final class GlobalVoiceOverlay {
    /// The transparent host must not resize with the island.  Letting SwiftUI derive the
    /// panel's intrinsic size while the island is spring-animating creates an AppKit
    /// update-constraints feedback loop.
    private static let panelSize = NSSize(width: 480, height: 260)
    private var window: NSPanel?
    private let model = OverlayModel()
    private var hideWork: DispatchWorkItem?
    private var visibilityGeneration = 0

    /// Create the window up front so the first hold paints immediately.
    func prepare() {
        ensureWindow()
        layout()
    }

    func show(message: String, image: String, busy: Bool, mode: VoiceOutputMode, showsModeSelector: Bool) {
        hideWork?.cancel()
        visibilityGeneration += 1
        let firstReveal = !model.expanded
        ensureWindow()
        layout()
        window?.orderFrontRegardless()
        window?.displayIfNeeded()
        model.update(message: message, image: image, busy: busy, mode: mode, showsModeSelector: showsModeSelector)
        if firstReveal {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.model.expanded else { return }
                withAnimation(OverlayModel.transition) {
                    self.model.expanded = true
                }
            }
        }
    }

    func updateQueue(_ items: [GlobalVoiceQueueItem]) {
        model.updateQueue(items)
    }

    func updateAudioLevel(_ level: Double) {
        model.updateAudioLevel(level)
    }

    func hide(after seconds: Double) {
        hideWork?.cancel()
        let generation = visibilityGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard generation == self.visibilityGeneration else { return }
            withAnimation(OverlayModel.transition) {
                self.model.expanded = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) { [weak self] in
                guard let self, generation == self.visibilityGeneration else { return }
                self.window?.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.minSize = Self.panelSize
        panel.maxSize = Self.panelSize
        let host = NSHostingController(rootView: DynamicIslandView(model: model))
        host.sizingOptions = []
        panel.contentViewController = host
        panel.setContentSize(Self.panelSize)
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

private struct IslandContentSizeKey: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}

private struct GlowRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    static let recording = GlowRGB(red: 1, green: 0, blue: 0)
    static let working = GlowRGB(red: 0.35, green: 0.55, blue: 1)
    static let success = GlowRGB(red: 0, green: 0.75, blue: 0.35)
    static let warning = GlowRGB(red: 1, green: 0.55, blue: 0)
    static let neutral = GlowRGB(red: 0.85, green: 0.85, blue: 0.9)
}

private struct GlowPalette: Equatable {
    let primary: GlowRGB
    let echo: GlowRGB

    static let recording = GlowPalette(
        primary: GlowRGB(red: 1, green: 0.04, blue: 0.1),
        echo: GlowRGB(red: 0.72, green: 0.12, blue: 0.88)
    )
    static let transcribing = GlowPalette(
        primary: GlowRGB(red: 0.24, green: 0.54, blue: 1),
        echo: GlowRGB(red: 0.04, green: 0.82, blue: 1)
    )
    static let translating = GlowPalette(
        primary: GlowRGB(red: 0.34, green: 0.4, blue: 1),
        echo: GlowRGB(red: 0.7, green: 0.22, blue: 1)
    )
    static let buildingPrompt = GlowPalette(
        primary: GlowRGB(red: 0.56, green: 0.26, blue: 1),
        echo: GlowRGB(red: 0.9, green: 0.16, blue: 0.62)
    )
    static let pasting = GlowPalette(
        primary: GlowRGB(red: 0.02, green: 0.74, blue: 0.7),
        echo: GlowRGB(red: 0.18, green: 0.5, blue: 1)
    )
    static let success = GlowPalette(
        primary: GlowRGB(red: 0, green: 0.75, blue: 0.35),
        echo: GlowRGB(red: 0, green: 0.76, blue: 0.72)
    )
    static let warning = GlowPalette(
        primary: GlowRGB(red: 1, green: 0.55, blue: 0),
        echo: GlowRGB(red: 1, green: 0.16, blue: 0.12)
    )
    static let neutral = GlowPalette(
        primary: GlowRGB(red: 0.82, green: 0.84, blue: 0.9),
        echo: GlowRGB(red: 0.34, green: 0.52, blue: 1)
    )
}

/// A dark, notch-merging surface with continuous "liquid" motion. The color field has
/// a little inertia, reacts gently to the microphone, and breathes while work is active.
private struct LiquidGlassSurface: View, Animatable {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var red: Double
    var green: Double
    var blue: Double
    var activity: Double
    var echoRed: Double
    var echoGreen: Double
    var echoBlue: Double
    var echoActivity: Double
    var processing: Bool
    var animating: Bool

    var animatableData: AnimatablePair<
        AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>,
        AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>
    > {
        get {
            AnimatablePair(
                AnimatablePair(AnimatablePair(red, green), AnimatablePair(blue, activity)),
                AnimatablePair(AnimatablePair(echoRed, echoGreen), AnimatablePair(echoBlue, echoActivity))
            )
        }
        set {
            red = newValue.first.first.first
            green = newValue.first.first.second
            blue = newValue.first.second.first
            activity = newValue.first.second.second
            echoRed = newValue.second.first.first
            echoGreen = newValue.second.first.second
            echoBlue = newValue.second.second.first
            echoActivity = newValue.second.second.second
        }
    }

    private var tint: Color {
        Color(red: red, green: green, blue: blue)
    }

    private var echoTint: Color {
        Color(red: echoRed, green: echoGreen, blue: echoBlue)
    }

    var body: some View {
        let shape = NotchIsland(topRadius: topRadius, bottomRadius: bottomRadius)
        // Only drive the per-frame display link while the island is actually on
        // screen. Collapsed into the notch the glow is invisible, so animating it
        // there just relaid out the whole hosting tree every frame forever (idle
        // main-thread burn that starved real frames the longer the app ran). A
        // static render while hidden costs nothing.
        if animating {
            TimelineView(.animation) { timeline in
                surface(shape, t: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            surface(shape, t: 0)
        }
    }

    @ViewBuilder
    private func surface(_ shape: NotchIsland, t: TimeInterval) -> some View {
        let drift = CGFloat(sin(t * 0.9))            // slow left/right sweep, -1…1
        let bob = CGFloat(sin(t * 1.3 + 1))          // gentle vertical shimmer
        let voice = CGFloat(min(max(activity, 0), 1))
        // Speech normally lands near the middle of the metered range. A curved
        // response makes that clearly visible while keeping silence at zero.
        let voiceResponse = pow(voice, 0.65)
        let echoVoice = CGFloat(min(max(echoActivity, 0), 1))
        let echoResponse = pow(echoVoice, 0.7)
        let breath = processing ? CGFloat(0.5 + 0.5 * sin(t * 2.15)) : 0
        let energy = min(voiceResponse * 0.9 + breath * 0.16, 1)
        GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    shape.fill(Color(white: 0.035 + Double(breath) * 0.006))
                    RadialGradient(colors: [tint.opacity(0.50 + Double(energy) * 0.30),
                                            tint.opacity(0.10 + Double(energy) * 0.09), .clear],
                                   center: .center, startRadius: 0, endRadius: w * 0.55)
                        .frame(width: w * (1.06 + voiceResponse * 0.18),
                               height: h * (1.92 + voiceResponse * 0.28 + breath * 0.06))
                        .position(x: w * 0.5 + drift * w * 0.26,
                                  y: h * (0.8 - voiceResponse * 0.06) + bob * h * 0.12)
                        .blur(radius: 16.5 - energy * 4)
                    RadialGradient(colors: [echoTint.opacity(0.18 + Double(echoResponse) * 0.24),
                                            echoTint.opacity(0.06 + Double(echoResponse) * 0.09), .clear],
                                   center: .center, startRadius: 0, endRadius: w * 0.48)
                        .frame(width: w * (0.78 + echoResponse * 0.17),
                               height: h * (1.48 + echoResponse * 0.24))
                        .position(x: w * 0.52 - drift * w * 0.2,
                                  y: h * (0.72 - echoResponse * 0.04) - bob * h * 0.08)
                        .blur(radius: 20 - echoResponse * 2.5)
                        .blendMode(.screen)
                    shape.fill(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.03), .clear],
                                              startPoint: .top, endPoint: .bottom))
                    shape.stroke(LinearGradient(colors: [.white.opacity(0.28 + Double(energy) * 0.18), .white.opacity(0.04)],
                                                startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
                }
                .clipShape(shape)
            }
    }
}

private struct DynamicIslandView: View {
    @ObservedObject var model: OverlayModel
    @State private var contentSize = CGSize.zero
    @State private var contentIsRevealed = false
    @State private var presentsModeSelector = false
    @State private var modeSelectorIsRevealed = false
    @State private var queueIsRevealed = false
    @State private var displayedMessage = ""
    @State private var messageOpacity = 1.0
    @State private var messageOffset: CGFloat = 0
    @State private var echoLevel = 0.0

    private var iconColor: Color {
        switch model.image {
        case "mic.fill": return .red
        case "checkmark.circle.fill": return .green
        case "mic.slash", "xmark.circle", "exclamationmark.triangle", "lock.shield": return .orange
        default: return .white.opacity(0.85)
        }
    }

    private var islandWidth: CGFloat {
        guard model.expanded else { return model.notchWidth }
        return min(max(contentSize.width, model.notchWidth), 430)
    }

    private var islandHeight: CGFloat {
        guard model.expanded else { return model.notchHeight }
        return model.notchHeight + contentSize.height + 15
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            contentBody
                .fixedSize()
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: IslandContentSizeKey.self, value: proxy.size)
                })
                .hidden()
            content
                .frame(width: islandWidth, height: islandHeight, alignment: .bottom)
                .background(islandSurface)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
                .animation(OverlayModel.transition, value: islandWidth)
                .animation(OverlayModel.transition, value: islandHeight)
        }
        .frame(width: 480, height: 260, alignment: .top)
        .onPreferenceChange(IslandContentSizeKey.self) { contentSize = $0 }
        .task(id: model.expanded) {
            guard model.expanded else {
                withAnimation(.easeIn(duration: 0.16)) {
                    contentIsRevealed = false
                }
                return
            }

            contentIsRevealed = false
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.30, extraBounce: 0)) {
                contentIsRevealed = true
            }
        }
        .task(id: model.showsModeSelector) {
            guard model.showsModeSelector else {
                withAnimation(.smooth(duration: 0.16, extraBounce: 0)) {
                    modeSelectorIsRevealed = false
                }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                withAnimation(OverlayModel.transition) {
                    presentsModeSelector = false
                }
                return
            }

            modeSelectorIsRevealed = false
            withAnimation(OverlayModel.transition) {
                presentsModeSelector = true
            }
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.24, extraBounce: 0)) {
                modeSelectorIsRevealed = true
            }
        }
        .task(id: model.message) {
            let nextMessage = model.message
            guard nextMessage != displayedMessage else { return }
            guard !displayedMessage.isEmpty else {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    displayedMessage = nextMessage
                    messageOpacity = 1
                    messageOffset = 0
                }
                return
            }

            // Switching 1/2/3 only changes the selected recording mode. Keep the
            // shared status text firmly in place; the highlighted capsule already
            // provides the visual transition and a fade here reads as a glitch.
            let modePrefixes = ["Recording · ", "Ready · "]
            if modePrefixes.contains(where: {
                displayedMessage.hasPrefix($0) && nextMessage.hasPrefix($0)
            }) {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    displayedMessage = nextMessage
                    messageOpacity = 1
                    messageOffset = 0
                }
                return
            }

            withAnimation(.easeIn(duration: 0.10)) {
                messageOpacity = 0
                messageOffset = -4
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                displayedMessage = nextMessage
                messageOffset = 4
            }
            withAnimation(.easeOut(duration: 0.16)) {
                messageOpacity = 1
                messageOffset = 0
            }
        }
        .task(id: model.audioLevel) {
            withAnimation(.easeOut(duration: 0.24)) {
                echoLevel = model.audioLevel
            }
        }
        .task(id: model.queueItems.map(\.id)) {
            guard !model.queueItems.isEmpty else {
                queueIsRevealed = false
                return
            }

            queueIsRevealed = false
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.24, extraBounce: 0)) {
                queueIsRevealed = true
            }
        }
    }

    // The glow color that moves inside the glass. On a black wallpaper the real
    // .glassEffect has nothing to refract, so this gives the surface visible life.
    private var glowPalette: GlowPalette {
        if model.image == "mic.fill" { return .recording }
        if model.image == "checkmark.circle.fill" { return .success }
        if ["mic.slash", "xmark.circle", "exclamationmark.triangle", "lock.shield"].contains(model.image) {
            return .warning
        }
        if model.busy {
            switch model.message.lowercased() {
            case let message where message.contains("transcrib"): return .transcribing
            case let message where message.contains("translat"): return .translating
            case let message where message.contains("building prompt"): return .buildingPrompt
            case let message where message.contains("past"): return .pasting
            default: return .transcribing
            }
        }
        switch model.image {
        default: return .neutral
        }
    }

    private var islandSurface: some View {
        let r: CGFloat = model.expanded ? 22 : 10
        let voiceActivity = model.image == "mic.fill" && !model.busy ? model.audioLevel : 0
        return LiquidGlassSurface(
            topRadius: model.hasNotch ? 0 : r,
            bottomRadius: r,
            red: glowPalette.primary.red,
            green: glowPalette.primary.green,
            blue: glowPalette.primary.blue,
            activity: voiceActivity,
            echoRed: glowPalette.echo.red,
            echoGreen: glowPalette.echo.green,
            echoBlue: glowPalette.echo.blue,
            echoActivity: echoLevel,
            processing: model.busy,
            animating: model.expanded
        )
        .animation(OverlayModel.glowTransition, value: glowPalette)
        .animation(.linear(duration: 0.10), value: model.audioLevel)
    }

    private var content: some View {
        contentBody
            .unfolded(contentIsRevealed, offset: 8)
    }

    private var contentBody: some View {
        VStack(spacing: 5) {
            statusContent
            if presentsModeSelector {
                modeSelector
            }
            if !model.queueItems.isEmpty {
                queueContent
            }
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 11)
    }

    private var statusContent: some View {
        HStack(spacing: 8) {
            Image(systemName: model.image)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 16, height: 16)
            Text(displayedMessage)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .frame(width: modeStatusWidth, alignment: .leading)
                .opacity(messageOpacity)
                .offset(y: messageOffset)
        }
    }

    private var modeSelector: some View {
        modeSelectorContent
            .settled(modeSelectorIsRevealed, offset: 6)
    }

    private var modeSelectorContent: some View {
        HStack(spacing: 5) {
            ForEach(VoiceOutputMode.allCases, id: \.rawValue) { mode in
                let selected = mode == model.mode
                HStack(spacing: 4) {
                    Text("\(mode.shortcut)")
                        .monospacedDigit()
                    Image(systemName: mode.icon)
                    Text(mode.title)
                }
                // Keep identical font metrics in every state so selection never
                // nudges the island or the neighboring buttons by a pixel.
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(selected ? mode.tint : Color.white.opacity(0.62))
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Capsule().fill(selected ? mode.tint.opacity(0.18) : Color.white.opacity(0.06)))
                .overlay(Capsule().stroke(selected ? mode.tint.opacity(0.7) : Color.white.opacity(0.12), lineWidth: 0.8))
            }
        }
        .animation(.smooth(duration: 0.16, extraBounce: 0), value: model.mode)
    }

    private var modeStatusWidth: CGFloat? {
        let prefixes = ["Recording · ", "Ready · "]
        return prefixes.contains(where: displayedMessage.hasPrefix) ? 126 : nil
    }

    private var queueContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider().overlay(.white.opacity(0.18))
            ForEach(model.queueItems.prefix(3)) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.isActive ? "waveform" : "clock")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(item.isActive ? Color.accentColor : .white.opacity(0.65))
                        .frame(width: 11)
                    Text(item.title)
                    Spacer(minLength: 8)
                    Text(item.detail)
                        .foregroundStyle(.white.opacity(0.58))
                }
                .font(.system(size: 10.5, weight: item.isActive ? .semibold : .medium))
                .lineLimit(1)
            }
            if model.queueItems.count > 3 {
                Text("+\(model.queueItems.count - 3) more waiting")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .unfolded(queueIsRevealed, offset: 5)
    }
}

private extension View {
    /// Reveals content from the bottom once the island has made room for it.
    /// A mask keeps controls from briefly appearing outside their final surface.
    func unfolded(_ isVisible: Bool, offset: CGFloat) -> some View {
        compositingGroup()
            .mask(alignment: .bottom) {
                Rectangle()
                    .scaleEffect(y: isVisible ? 1 : 0, anchor: .bottom)
            }
            .offset(y: isVisible ? 0 : offset)
    }

    /// Lets controls settle into their reserved space without scaling a dark mask.
    func settled(_ isVisible: Bool, offset: CGFloat) -> some View {
        opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : -offset)
            .scaleEffect(isVisible ? 1 : 0.98, anchor: .top)
    }
}

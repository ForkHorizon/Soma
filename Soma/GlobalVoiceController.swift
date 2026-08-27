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
        case 18, 83: return .original  // 1, keypad 1
        case 19, 84: return .english  // 2, keypad 2
        case 20, 85: return .prompt  // 3, keypad 3
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

    func setRightCommandDown(_ isDown: Bool) {
        lock.lock()
        rightCommandDown = isDown
        lock.unlock()
    }

    func isRightCommandDown() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return rightCommandDown
    }

    func shouldConsume(type: CGEventType, keyCode: Int) -> Bool {
        guard type == .keyDown || type == .keyUp, VoiceOutputMode.mode(forKeyCode: keyCode) != nil else { return false }
        lock.lock()
        defer { lock.unlock() }
        return rightCommandDown
    }
}

/// Runs the CGEvent tap on its OWN thread/runloop, never the main one. An active
/// session tap whose callback is served by a busy main thread freezes ALL system
/// input until the OS times the tap out — which also looked like a random
/// "Canceled" mid-recording. On a dedicated thread the callback is always served
/// promptly regardless of UI/system load.
private final class EventTapRunner: @unchecked Sendable {
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?

    nonisolated init() {}

    private func adoptRunLoop(_ rl: CFRunLoop) { runLoop = rl }

    func start(tap: CFMachPort) {
        stop()
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runner = self
        let worker = Thread {
            guard let rl = CFRunLoopGetCurrent() else { return }
            runner.adoptRunLoop(rl)
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            while !Thread.current.isCancelled {
                _ = autoreleasepool {
                    CFRunLoopRunInMode(.defaultMode, 0.5, false)
                }
            }
            CFRunLoopRemoveSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        worker.name = "com.soma.global-voice-tap"
        worker.stackSize = 512 * 1024
        thread = worker
        worker.start()
    }

    /// Re-enable after the OS disabled the tap (timeout / user input). Touches no
    /// app state, so recovering the tap can never cancel a recording.
    func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func stop() {
        thread?.cancel()
        if let runLoop { CFRunLoopStop(runLoop) }
        thread = nil
        runLoop = nil
        tap = nil
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
    private var holdTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var permissionRetryTask: Task<Void, Never>?
    private var systemStateObserversRegistered = false

    private var rightCommandDown = false
    private var comboUsed = false
    private var recording = false
    private var recordingMode: VoiceOutputMode = .current
    private var recordingTargetApplication: NSRunningApplication?
    private var activeJob: GlobalVoiceJob?
    private var queuedJobs = GlobalVoiceFIFO<GlobalVoiceJob>()
    private let overlay = GlobalVoiceOverlay()
    nonisolated private let keyCapture = RightCommandModeKeyCapture()
    nonisolated private let tapRunner = EventTapRunner()

    private let rightCommandKeyCode = 54
    private let escapeKeyCode = 53
    private let pasteKeyCode: CGKeyCode = 9

    /// Device-dependent flag bit set only while the *right* Command key is down
    /// (NX_DEVICERCMDKEYMASK). Reading it makes key tracking level-based.
    nonisolated static let rightCommandDeviceMask: UInt64 = 0x0000_0010

    func configure(
        asr: ASRManager, somaViewModel: SomaViewModel, ollama: OllamaManager, prompter: RusToPromptViewModel,
        textPriorityQueue: VoiceTextPriorityQueue
    ) {
        self.asr = asr
        self.somaViewModel = somaViewModel
        self.ollama = ollama
        self.prompter = prompter
        self.textPriorityQueue = textPriorityQueue
        registerSystemStateObservers()

    }

    func setEnabled(_ enabled: Bool, promptForPermission: Bool = false) {
        if enabled {
            guard accessibilityTrusted(prompt: promptForPermission) else {
                needsAccessibilityPermission = true
                stopEventTap()
                startPermissionRetry()
                if promptForPermission {
                    show("Allow Accessibility access to use Right Command paste.", image: "lock.shield")
                } else {
                    status = "Right Command paste needs Accessibility access."
                }
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

    /// Sleep/wake scramble global event-tap modifier state (a key-up can arrive
    /// while the tap is suspended). Resync on wake so we never resume with a
    /// phantom "still recording" island. Controller is app-lifetime, so the
    /// observers are never removed. ponytail: no teardown for a singleton.
    private func registerSystemStateObservers() {
        guard !systemStateObserversRegistered else { return }
        systemStateObserversRegistered = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resyncModifierState() }
            }
        }
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
        let mask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let controller = Unmanaged<GlobalVoiceController>.fromOpaque(refcon).takeUnretainedValue()
                    // Recover the tap right here on the tap thread — never depend on the
                    // main thread (which may be what stalled us) to re-enable it, and
                    // never let a timeout cancel an in-progress recording.
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        controller.tapRunner.reenable()
                        return nil
                    }
                    let rawType = type.rawValue
                    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
                    // Level-based: read whether the right Command key is *actually* down
                    // from the event's device flags, instead of toggling a parity bit.
                    // A dropped flagsChanged (tap timeout / sleep) then can't invert the
                    // state and strand a phantom recording.
                    let rightCommandIsDown = (event.flags.rawValue & GlobalVoiceController.rightCommandDeviceMask) != 0
                    let consumeEvent = controller.captureEvent(type: type, keyCode: keyCode, rightCommandIsDown: rightCommandIsDown)

                    // The event tap sees every global keystroke. Only hop to the main
                    // actor for an event that can change Soma's state; posting a Task
                    // for ordinary typing creates needless main-queue churn all day.
                    let needsMainActor =
                        (type == .flagsChanged && keyCode == 54)
                        || (type == .keyDown && (consumeEvent || controller.keyCapture.isRightCommandDown()))
                    if needsMainActor {
                        Task { @MainActor in
                            controller.handleTapEvent(
                                rawType: rawType, keyCode: keyCode, rightCommandIsDown: rightCommandIsDown, modeKeyWasCaptured: consumeEvent
                            )
                        }
                    }
                    return consumeEvent ? nil : Unmanaged.passUnretained(event)
                },
                userInfo: refcon
            )
        else {
            needsAccessibilityPermission = true
            show("Could not start Right Command listener. Check Accessibility access.", image: "exclamationmark.triangle")
            return
        }
        eventTap = tap
        tapRunner.start(tap: tap)  // runs on its own thread, off the main runloop
        overlay.prepare()
        status = "Hold Right Command to record, release to paste."
    }

    private func stopEventTap() {
        holdTask?.cancel()
        holdTask = nil
        if recording || asr?.isRecording == true {
            cancel()
        }
        tapRunner.stop()
        eventTap = nil
        keyCapture.setRightCommandDown(false)
        rightCommandDown = false
        comboUsed = false
    }

    nonisolated private func captureEvent(type: CGEventType, keyCode: Int, rightCommandIsDown: Bool) -> Bool {
        if type == .flagsChanged, keyCode == 54 {
            keyCapture.setRightCommandDown(rightCommandIsDown)
            return false
        }
        return keyCapture.shouldConsume(type: type, keyCode: keyCode)
    }

    private func handleTapEvent(rawType: UInt32, keyCode: Int, rightCommandIsDown: Bool, modeKeyWasCaptured: Bool) {
        // tapDisabled events are recovered on the tap thread (see the callback) and
        // never reach here — deliberately: re-enabling must not cancel a recording.
        if rawType == CGEventType.flagsChanged.rawValue, keyCode == rightCommandKeyCode {
            setRightCommand(down: rightCommandIsDown)
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
        watchdogTask?.cancel()
        watchdogTask = nil
        guard recording else { return }
        recording = false
        // Closing the audio file happens on the serial audio queue and can take a
        // moment. Do not leave the island claiming that it is still recording
        // while that work completes: the key release has already been handled.
        show("Finishing…", image: "waveform", busy: true, mode: recordingMode)
        finishAndPaste(using: recordingMode)
    }

    /// Drive the key transition from the real, level-based flag state. Repeated
    /// same-state events (key-repeat, left+right combos) are ignored.
    private func setRightCommand(down: Bool) {
        guard down != rightCommandDown else { return }
        down ? rightCommandDownEvent() : rightCommandUp()
    }

    /// Force key state back to "released" and tear down any in-flight recording.
    /// Called when the tap re-enables after a timeout and on system wake, where
    /// dropped events would otherwise desync tracking and strand the island.
    private func resyncModifierState() {
        keyCapture.setRightCommandDown(false)
        holdTask?.cancel()
        holdTask = nil
        comboUsed = false
        if recording || asr?.isRecording == true {
            cancel()
        } else {
            rightCommandDown = false
        }
    }

    private func startRecordingIfStillHeld() {
        guard rightCommandDown, !comboUsed, !recording else { return }
        guard let asr, !asr.isRecording else { return }
        recordingTargetApplication = NSWorkspace.shared.frontmostApplication
        recording = true
        refreshOverlay()
        asr.startGlobalRecording()
        scheduleRecordingWatchdog()
    }

    /// Hard ceiling: even if every other guard fails, a stuck key can't keep the
    /// recorder — and the island's animated glow — alive for more than a few
    /// minutes. Normal hold-to-talk lasts seconds, so this never bites real use.
    private func scheduleRecordingWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000_000)  // 3 min
            guard let self, !Task.isCancelled, self.recording else { return }
            self.cancel()
        }
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
            queuedJobs.enqueue(
                GlobalVoiceJob(
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
            VoiceMetrics.log(
                "global_final_asr",
                [
                    "release_to_final_milliseconds": "\(Int(Date().timeIntervalSince(transcriptionStartedAt) * 1_000))"
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
            show(
                activeJob.phase.rawValue, image: activeJob.phase == .pasting ? "doc.on.clipboard" : "waveform", busy: true,
                mode: activeJob.mode)
        } else if !queuedJobs.isEmpty {
            show("\(queuedJobs.count) recording\(queuedJobs.count == 1 ? "" : "s") queued", image: "clock", busy: true)
        }
    }

    private var queueItems: [GlobalVoiceQueueItem] {
        var items: [GlobalVoiceQueueItem] = []
        if let activeJob {
            items.append(
                GlobalVoiceQueueItem(
                    id: activeJob.id,
                    title: "Now · \(activeJob.mode.title)",
                    detail: activeJob.phase.rawValue,
                    isActive: true
                ))
        }
        items.append(
            contentsOf: queuedJobs.elements.enumerated().map { index, job in
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
        watchdogTask?.cancel()
        watchdogTask = nil
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
        VoiceMetrics.log(
            "translation_finished",
            [
                "duration_milliseconds": "\(Int(Date().timeIntervalSince(translationStartedAt) * 1_000))"
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
        VoiceMetrics.log(
            "prompt_generation_finished",
            [
                "duration_milliseconds": "\(Int(Date().timeIntervalSince(promptStartedAt) * 1_000))"
            ])
        return prompter.finalPromptForCopy
    }

    private func paste(_ text: String, into app: NSRunningApplication?) async {
        let startedAt = Date()
        defer {
            VoiceMetrics.log(
                "paste_finished",
                [
                    "duration_milliseconds": "\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
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
        let isModeSwitch =
            self.showsModeSelector && showsModeSelector
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
        // Keep one hosting tree for the app lifetime. Rebuilding a complete
        // SwiftUI tree for every dictation steadily grew Observation state over
        // long sessions. LiquidGlassSurface itself stops all motion once the
        // island is collapsed, so keeping this host costs no idle animation.
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
            model.notchWidth = r.minX - l.maxX  // real notch (camera) width
        } else {
            model.notchWidth = 180  // no notch: floating top pill
        }
        let full = screen.frame
        // Notch Macs: flush to the top bezel so it merges with the camera cutout.
        // No-notch Macs: drop just below the menu bar as a floating pill.
        let topEdge = model.hasNotch ? full.maxY : screen.visibleFrame.maxY - 6
        // A newly attached NSHostingController can briefly report its intrinsic
        // width. The panel itself is always fixed-size; centering from that
        // transient width makes the first reveal appear shifted until AppKit
        // applies the real frame on a later update.
        window.setFrame(
            NSRect(
                x: full.midX - Self.panelSize.width / 2,
                y: topEdge - Self.panelSize.height,
                width: Self.panelSize.width,
                height: Self.panelSize.height
            ),
            display: window.isVisible
        )
    }
}

/// A rounded-bottom, square-top shape so the top edge sits flush with the screen bezel
/// and the body drops out of the camera notch like Dynamic Island.
private struct NotchIsland: Shape {
    var topRadius: CGFloat = 0  // 0 = square top (flush to notch); >0 = rounded pill
    var bottomRadius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let tr = topRadius
        let br = bottomRadius
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
    @State private var driftPhase: CGFloat = 0
    @State private var bobPhase: CGFloat = 0
    @State private var breathPhase: CGFloat = 0

    var animatableData:
        AnimatablePair<
            AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>,
            AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>
        >
    {
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
        // Do not use TimelineView here: it re-runs this entire SwiftUI body for
        // every display frame. These repeat-forever values are interpolated by
        // SwiftUI's animation system instead, and reset to a static surface when
        // the panel is hidden.
        surface(
            shape,
            drift: animating ? driftPhase : 0,
            bob: animating ? bobPhase : 0,
            breath: animating && processing ? breathPhase : 0
        )
        .drawingGroup()
        .onAppear { updateMotion(isActive: animating) }
        .onChange(of: animating) { _, isActive in
            updateMotion(isActive: isActive)
        }
    }

    @ViewBuilder
    private func surface(_ shape: NotchIsland, drift: CGFloat, bob: CGFloat, breath: CGFloat) -> some View {
        let voice = CGFloat(min(max(activity, 0), 1))
        // Speech normally lands near the middle of the metered range. A curved
        // response makes that clearly visible while keeping silence at zero.
        let voiceResponse = pow(voice, 0.65)
        let echoVoice = CGFloat(min(max(echoActivity, 0), 1))
        let echoResponse = pow(echoVoice, 0.7)
        let energy = min(voiceResponse * 0.9 + breath * 0.16, 1)
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                shape.fill(Color(white: 0.035 + Double(breath) * 0.006))
                RadialGradient(
                    colors: [
                        tint.opacity(0.50 + Double(energy) * 0.30),
                        tint.opacity(0.10 + Double(energy) * 0.09), .clear,
                    ],
                    center: .center, startRadius: 0, endRadius: w * 0.55
                )
                .frame(
                    width: w * (1.06 + voiceResponse * 0.18),
                    height: h * (1.92 + voiceResponse * 0.28 + breath * 0.06)
                )
                .position(
                    x: w * 0.5 + drift * w * 0.26,
                    y: h * (0.8 - voiceResponse * 0.06) + bob * h * 0.12
                )
                .blur(radius: 16.5 - energy * 4)
                RadialGradient(
                    colors: [
                        echoTint.opacity(0.18 + Double(echoResponse) * 0.24),
                        echoTint.opacity(0.06 + Double(echoResponse) * 0.09), .clear,
                    ],
                    center: .center, startRadius: 0, endRadius: w * 0.48
                )
                .frame(
                    width: w * (0.78 + echoResponse * 0.17),
                    height: h * (1.48 + echoResponse * 0.24)
                )
                .position(
                    x: w * 0.52 - drift * w * 0.2,
                    y: h * (0.72 - echoResponse * 0.04) - bob * h * 0.08
                )
                .blur(radius: 20 - echoResponse * 2.5)
                .blendMode(.screen)
                shape.fill(
                    LinearGradient(
                        colors: [.white.opacity(0.18), .white.opacity(0.03), .clear],
                        startPoint: .top, endPoint: .bottom))
                shape.stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.28 + Double(energy) * 0.18), .white.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
            }
            .clipShape(shape)
        }
    }

    private func updateMotion(isActive: Bool) {
        guard isActive else {
            withAnimation(nil) {
                driftPhase = 0
                bobPhase = 0
                breathPhase = 0
            }
            return
        }

        withAnimation(nil) {
            driftPhase = -1
            bobPhase = -1
            breathPhase = 0
        }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                driftPhase = 1
            }
            withAnimation(.easeInOut(duration: 1.65).repeatForever(autoreverses: true)) {
                bobPhase = 1
            }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                breathPhase = 1
            }
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
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: IslandContentSizeKey.self, value: proxy.size)
                    }
                )
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
            // The meter arrives at 10 Hz. Keeping both glows in the same short
            // transaction prevents a new 0.24 s animation from constantly
            // overtaking the previous value and then jumping ahead.
            echoActivity: model.audioLevel,
            processing: model.busy,
            animating: model.expanded
        )
        .animation(OverlayModel.glowTransition, value: glowPalette)
        .animation(.linear(duration: 0.08), value: model.audioLevel)
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

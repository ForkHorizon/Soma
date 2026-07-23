//
//  SomaApp.swift
//  Soma
//
//  Created by Кирилл Щербо on 18/04/2026.
//

import AppKit
import SwiftUI

@main
struct SomaApp: App {
    @StateObject private var viewModel = SomaViewModel()
    // Shared so the popped-out Tests window uses the same queue/model state as the main window.
    @StateObject private var ollama = OllamaManager()
    @StateObject private var queueManager = RusToPromptQueueManager()
    // Global voice must outlive any individual WindowGroup window. Otherwise
    // every open main window creates its own event tap and pastes independently.
    @StateObject private var voiceASR = ASRManager()
    @StateObject private var voicePrompter = RusToPromptViewModel()
    @StateObject private var globalVoice = GlobalVoiceController()
    @StateObject private var voiceTextPriorityQueue = VoiceTextPriorityQueue()

    var body: some Scene {
        WindowGroup {
            ContentView(
                viewModel: viewModel,
                ollama: ollama,
                rusToPromptQueueManager: queueManager,
                voiceASR: voiceASR,
                voicePrompter: voicePrompter,
                globalVoice: globalVoice,
                textPriorityQueue: voiceTextPriorityQueue
            )
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                globalVoice.setEnabled(false)
                voiceASR.cancelRecording()
            }
        }
        Window("Tests", id: "tests") {
            TestsView(mode: .full, ollama: ollama, queueManager: queueManager)
                .frame(minWidth: 1120, minHeight: 700)
        }
    }
}

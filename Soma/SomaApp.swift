//
//  SomaApp.swift
//  Soma
//
//  Created by Кирилл Щербо on 18/04/2026.
//

import SwiftUI

@main
struct SomaApp: App {
    @StateObject private var viewModel = SomaViewModel()
    // Shared so the popped-out Tests window uses the same queue/model state as the main window.
    @StateObject private var ollama = OllamaManager()
    @StateObject private var queueManager = RusToPromptQueueManager()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel, ollama: ollama, rusToPromptQueueManager: queueManager)
        }
        Window("Tests", id: "tests") {
            TestsView(mode: .full, ollama: ollama, queueManager: queueManager)
                .frame(minWidth: 1120, minHeight: 700)
        }
    }
}

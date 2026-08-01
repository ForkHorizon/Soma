import SwiftUI

/// The detail pane's route table, lifted out of ContentView so adding a route
/// is a one-line change in a small file instead of growth in an already
/// oversized one. Pure dispatch — no state of its own.
struct AppRouteDetail: View {
    let route: AppRoute
    @ObservedObject var viewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager
    @ObservedObject var rusToPromptQueueManager: RusToPromptQueueManager
    @ObservedObject var voiceASR: ASRManager
    @ObservedObject var voicePrompter: RusToPromptViewModel
    @ObservedObject var globalVoice: GlobalVoiceController
    @ObservedObject var textPriorityQueue: VoiceTextPriorityQueue
    @ObservedObject var groundTruth: GroundTruthRunner
    @ObservedObject var rusToPromptViewModel: RusToPromptViewModel
    @ObservedObject var promptCompilerViewModel: PromptCompilerViewModel

    var body: some View {
        switch route {
        case .rusToPrompt:
            RusToPromptView(viewModel: rusToPromptViewModel, somaViewModel: viewModel, ollama: ollama, queueManager: rusToPromptQueueManager)
        case .voiceToText:
            VoiceToTextView(somaViewModel: viewModel, ollama: ollama, asr: voiceASR, prompter: voicePrompter, globalVoice: globalVoice, textPriorityQueue: textPriorityQueue)
        case .groundTruth:
            GroundTruthView(asr: voiceASR, runner: groundTruth)
        case .queue:
            TestsView(mode: .queue, ollama: ollama, queueManager: rusToPromptQueueManager)
        case .modelStats:
            TestsView(mode: .stats, ollama: ollama, queueManager: rusToPromptQueueManager)
        case .tests:
            TestsView(mode: .full, ollama: ollama, queueManager: rusToPromptQueueManager)
        case .promptCompiler:
            PromptCompilerView(viewModel: promptCompilerViewModel, somaViewModel: viewModel, ollama: ollama)
        case .localAI:
            LocalAISettingsView(viewModel: viewModel, ollama: ollama)
        case .logs:
            LogsView(viewModel: viewModel, ollama: ollama)
        case .tokenCalculator:
            TokenCalculatorView(viewModel: viewModel)
        case .systemStatus:
            SystemStatusView(viewModel: viewModel, ollama: ollama)
        case .extensions:
            ToolVersionsView(viewModel: viewModel)
        case .projectOverview:
            ProjectOverviewView(viewModel: viewModel)
        }
    }
}

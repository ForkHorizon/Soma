import Foundation
import SwiftUI

enum AppMode: String, CaseIterable, Identifiable {
    case scout = "Scout"
    case relay = "Relay"

    var id: String { rawValue }
}

enum AnalysisDepth: String, CaseIterable, Identifiable, Codable {
    case deterministic
    case ranked
    case analyst

    var id: String { rawValue }
    var label: String {
        switch self {
        case .deterministic: return "Deterministic"
        case .ranked: return "Ranker"
        case .analyst: return "Analyst"
        }
    }
}

enum RelayPhase: Equatable {
    case idle
    case gathering
    case relaying
    case done
    case failed(String)
}

struct SomaError: LocalizedError {
    let msg: String
    init(_ msg: String) { self.msg = msg }
    var errorDescription: String? { msg }
}

enum AppRoute: String, Hashable, CaseIterable {
    case rusToPrompt = "Rus to Prompt"
    case voiceToText = "Voice to Text"
    case queue = "Queue"
    case modelStats = "Model Stats"
    case tests = "Tests"
    case promptCompiler = "Prompt Builder"
    case localAI = "Local AI"
    case logs = "Activity"
    case tokenCalculator = "Token Calculator"
    case systemStatus = "System Status"
    case extensions = "Extensions"

    var title: String { rawValue }

    static var visibleRoutes: [AppRoute] {
        [.rusToPrompt, .voiceToText, .queue, .modelStats, .tests,
         .promptCompiler, .localAI, .tokenCalculator, .logs, .systemStatus, .extensions]
    }

    var section: String {
        switch self {
        case .rusToPrompt, .voiceToText, .queue, .modelStats, .tests:
            return "Main"
        case .logs:
            return "History"
        case .promptCompiler, .localAI, .tokenCalculator, .systemStatus, .extensions:
            return "Advanced"
        }
    }

    var description: String {
        switch self {
        case .rusToPrompt:
            return "Translate Russian prompts to English and polish them without project context."
        case .voiceToText:
            return "Record speech and transcribe it locally with Mega-ASR."
        case .queue:
            return "Real prompt queue: enqueue, monitor, and run benchmark jobs."
        case .modelStats:
            return "Model performance stats across translation and improver runs."
        case .tests:
            return "Run prompt cases across local and cloud models and compare."
        case .promptCompiler:
            return "Improve a rough prompt before sending it to a model."
        case .localAI:
            return "Set global local model roles."
        case .logs:
            return "Review activity and logs."
        case .tokenCalculator:
            return "Estimate prompt size and token cost."
        case .systemStatus:
            return "Runtime and model diagnostics."
        case .extensions:
            return "Check and update globally-installed tools (Graphify, Ponytail, Serena)."
        }
    }

    var systemImage: String {
        switch self {
        case .rusToPrompt:
            return "character.bubble"
        case .voiceToText:
            return "waveform"
        case .queue:
            return "tray.full"
        case .modelStats:
            return "chart.bar.xaxis"
        case .tests:
            return "testtube.2"
        case .promptCompiler:
            return "wand.and.stars"
        case .localAI:
            return "cpu"
        case .logs:
            return "waveform.path"
        case .tokenCalculator:
            return "number.square"
        case .systemStatus:
            return "stethoscope"
        case .extensions:
            return "puzzlepiece.extension"
        }
    }
}

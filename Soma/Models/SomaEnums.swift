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
    case relay = "Prepare Packet"
    case rusToPrompt = "Rus to Prompt"
    case tests = "Tests"
    case projectSetup = "Project Setup"
    case packets = "Packets"
    case diagnostics = "Diagnostics"
    case projects = "Projects"
    case promptCompiler = "Prompt Builder"
    case localAI = "Local AI"
    case projectHealth = "Project Health"
    case logs = "Activity"
    case externalTools = "Utilities"
    case tokenCalculator = "Token Calculator"
    case systemStatus = "System Status"
    #if DEBUG
    case redesignMock = "UI Mock"
    #endif

    var title: String { rawValue }

    static var visibleRoutes: [AppRoute] {
        [.relay, .rusToPrompt, .tests, .projectSetup, .packets, .diagnostics]
    }

    var section: String {
        switch self {
        case .relay, .rusToPrompt, .tests:
            return "Main"
        case .projectSetup, .projects, .projectHealth:
            return "Project"
        case .packets, .logs:
            return "History"
        case .diagnostics, .promptCompiler, .localAI, .externalTools, .tokenCalculator, .systemStatus:
            return "Advanced"
        #if DEBUG
        case .redesignMock:
            return "Advanced"
        #endif
        }
    }

    var description: String {
        switch self {
        case .relay:
            return "Prepare compact evidence for a coding model."
        case .rusToPrompt:
            return "Translate Russian prompts to English and polish them without project context."
        case .tests:
            return "Run and review Soma test workflows."
        case .projectSetup:
            return "Simple project readiness without runtime noise."
        case .packets:
            return "Real packet runs and usefulness feedback."
        case .diagnostics:
            return "Advanced runtime, MCP, graph, logs, and utility screens."
        case .projects:
            return "Open or switch the active workspace."
        case .promptCompiler:
            return "Improve a rough prompt before packet work."
        case .localAI:
            return "Set global local model roles."
        case .projectHealth:
            return "Review project readiness and graph state."
        case .logs:
            return "Review activity, audit traces, and logs."
        case .externalTools:
            return "Optional Scout, Token Calculator, diagnostics, and future-roadmap shelf."
        case .tokenCalculator:
            return "Estimate prompt and packet size inside Soma."
        case .systemStatus:
            return "Expert runtime and MCP diagnostics."
        #if DEBUG
        case .redesignMock:
            return "Preview the redesigned core screens."
        #endif
        }
    }

    var systemImage: String {
        switch self {
        case .relay:
            return "doc.text.magnifyingglass"
        case .rusToPrompt:
            return "character.bubble"
        case .tests:
            return "testtube.2"
        case .projectSetup:
            return "checklist"
        case .packets:
            return "tray.full"
        case .diagnostics:
            return "stethoscope"
        case .projects:
            return "folder.fill"
        case .promptCompiler:
            return "wand.and.stars"
        case .localAI:
            return "cpu"
        case .projectHealth:
            return "waveform.path.ecg"
        case .logs:
            return "waveform.path"
        case .externalTools:
            return "wrench.and.screwdriver"
        case .tokenCalculator:
            return "number.square"
        case .systemStatus:
            return "stethoscope"
        #if DEBUG
        case .redesignMock:
            return "sparkles.rectangle.stack"
        #endif
        }
    }
}

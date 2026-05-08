import Foundation
import SwiftUI

enum AppMode: String, CaseIterable, Identifiable {
    case scout = "🐶  Scout"
    case relay = "🔗  Relay"

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
    case relay = "Evidence Relay"
    case scout = "Scout Mode"
    case systemStatus = "System Status"
}

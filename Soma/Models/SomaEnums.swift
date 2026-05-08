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

struct SomaGatewayStatus: Codable, Sendable {
    let status: String?
    let project_root: String?
    let server: SomaServerInfo?
    let nexus: SomaNexusStatus?
    let graph: SomaGraphStatus?
}

struct SomaServerInfo: Codable, Sendable {
    let transport: String?
    let tool_count: Int?
    let tool_names: [String]?
}

struct SomaNexusStatus: Codable, Sendable {
    let connected: Bool?
    let port: Int?
    let session_id: String?
    let session_generation: Int?
    let busy_reason: String?
}

struct SomaGraphStatus: Codable, Sendable {
    let available: Bool?
    let project_graph_available: Bool?
    let stale: Bool?
    let recommended_action: String?
}

struct ClientConfigStatus: Codable, Sendable {
    let status: String
    let summary: String
    let config_path: String?
    let soma_installed: Bool?
    let direct_nexus_exposed: Bool?
    let tool_exposure_clean: Bool?
    let issues: [String]
}

struct ClientConfigInstallStatus: Codable, Sendable {
    let status: String
    let summary: String
    let config_path: String?
    let backup_path: String?
    let soma_installed: Bool?
    let direct_nexus_removed: Bool?
    let old_soma_blocks_replaced: Int?
    let issues: [String]
}

struct ClientConfigRollbackStatus: Codable, Sendable {
    let status: String
    let summary: String
    let config_path: String?
    let backup_path: String?
    let restored: Bool?
    let post_restore_status: String?
    let post_restore_issues: [String]?
    let issues: [String]?
}

struct LiveVerifyStatus: Codable, Sendable {
    let status: String
    let project_root: String?
    let issues: [String]?
    let tools: LiveVerifyTools?
    let nexus: SomaNexusStatus?
    let graph: SomaGraphStatus?
    let calls: [String: LiveVerifyCall]?
}

struct LiveVerifyTools: Codable, Sendable {
    let count: Int?
    let expected_count: Int?
    let unity_exposed: [String]?
}

struct LiveVerifyCall: Codable, Sendable {
    let status: String?
    let summary: String?
    let instance_id: Int?
    let path: String?
}

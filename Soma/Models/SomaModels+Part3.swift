import Foundation
import SwiftUI

struct AnyCodable: Codable, Sendable {
    let value: Sendable

    init(_ value: Sendable) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil()                                          { self.value = JSONNull() }
        else if let value = try? container.decode(String.self)            { self.value = value }
        else if let value = try? container.decode(Int.self)               { self.value = value }
        else if let value = try? container.decode(Double.self)            { self.value = value }
        else if let value = try? container.decode(Bool.self)             { self.value = value }
        else if let value = try? container.decode([String: AnyCodable].self) { self.value = value }
        else if let value = try? container.decode([AnyCodable].self)     { self.value = value }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown type") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value = value as? String                     { try container.encode(value) }
        else if let value = value as? Int                  { try container.encode(value) }
        else if let value = value as? Double               { try container.encode(value) }
        else if let value = value as? Bool                 { try container.encode(value) }
        else if let value = value as? [String: AnyCodable] { try container.encode(value) }
        else if let value = value as? [AnyCodable]         { try container.encode(value) }
        else if value is JSONNull                          { try container.encodeNil() }
    }
}

extension AnyCodable {
    var displayValue: String {
        if let value = value as? String { return value }
        if let value = value as? Int { return String(value) }
        if let value = value as? Double { return String(format: "%.2f", value) }
        if let value = value as? Bool { return value ? "true" : "false" }
        if value is JSONNull { return "null" }
        return String(describing: value)
    }
}

// Consolidated status models

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
    let project_path: String?
    let session_id: String?
    let session_generation: Int?
    let unity_version: String?
    let busy_reason: String?
}

struct SomaGraphStatus: Codable, Sendable {
    let available: Bool?
    let project_graph_available: Bool?
    let managed_available: Bool?
    let legacy_available: Bool?
    let storage_kind: String?
    let stale: Bool?
    let node_count: Int?
    let edge_count: Int?
    let storage_path: String?
    let managed_path: String?
    let legacy_paths: [String]?
    let graphify_version: String?
    let tool_version: String?
    let graph_degraded: Bool?
    let graph_degraded_reason: String?
    let diagnostics_path: String?
    let graph_source_root: String?
    let graph_scope: String?
    let recommended_action: String?
}

struct GraphStorageInfo: Codable, Sendable {
    let project_id: String?
    let project_root: String?
    let display_name: String?
    let project_dir: String?
    let output_root: String?
    let graph_dir: String?
    let graph_json: String?
    let graph_source_root: String?
    let graph_scope: String?
    let legacy_paths: [String]?
}

struct GraphifyToolStatus: Codable, Sendable {
    let status: String?
    let installed_version: String?
    let latest_version: String?
    let up_to_date: Bool?
    let recommended_action: String?
}

struct GraphMaintenanceResult: Codable, Sendable {
    let status: String?
    let summary: String?
    let mode: String?
    let refreshed: Int?
    let skipped: Int?
    let failed: Int?
    let warnings: [String]?
    let graph: SomaGraphStatus?
}

struct GraphReportResult: Codable, Sendable {
    let status: String?
    let summary: String?
    let output_path: String?
}

struct GraphSemanticUpdateStatus: Codable, Sendable {
    let status: String?
    let summary: String?
    let pending: Bool?
}

struct ClientConfigStatus: Codable, Sendable {
    let status: String
    let summary: String
    let config_path: String?
    let soma_installed: Bool?
    let direct_nexus_exposed: Bool?
    let tool_exposure_clean: Bool?
    let actual_project_root: String?
    let expected_project_root: String?
    let project_matches: Bool?
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
    let actual_project_root: String?
    let expected_project_root: String?
    let project_matches: Bool?
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

struct ProjectAISetupReport: Codable, Sendable {
    let status: String?
    let summary: String?
    let generated_at: String?
    let updated_at: String?
    let project_root: String?
    let mode: String?
    let files_inspected: [ProjectAISetupFile]?
    let files_changed: [ProjectAISetupChangedFile]?
    let backups: [ProjectAISetupBackup]?
    let issues: [String]?
    let removed_direct_mcp_servers: [String]?
    let inserted_or_updated_prompt_blocks: [String]?
    let verification: ProjectAISetupVerification?
    let remaining_risks: [String]?
    let local_ai_checks: [ProjectAISetupLocalCheck]?
    let report_path: String?
}

struct ProjectAISetupFile: Codable, Sendable, Identifiable {
    var id: String { path ?? label ?? UUID().uuidString }
    let label: String?
    let path: String?
    let exists: Bool?
    let issues: [String]?
    let direct_markers: [String]?
    let soma_first_block: Bool?
    let size: Int?
}

struct ProjectAISetupChangedFile: Codable, Sendable, Identifiable {
    var id: String { path ?? UUID().uuidString }
    let path: String?
    let backup_path: String?
}

struct ProjectAISetupBackup: Codable, Sendable, Identifiable {
    var id: String { "\(path ?? "")-\(backup_path ?? "")" }
    let path: String?
    let backup_path: String?
}

struct ProjectAISetupVerification: Codable, Sendable {
    let status: String?
    let remaining_issues: [String]?
}

struct ProjectAISetupLocalCheck: Codable, Sendable, Identifiable {
    var id: String { stage ?? UUID().uuidString }
    let stage: String?
    let status: String?
    let model: String?
    let reason: String?
    let error: String?
    let warnings: [String]?
    let notes: [String]?
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

import Foundation
import SwiftUI

extension DateFormatter {
    static let somaDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}


struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String?
}

struct OllamaResponse: Codable, Sendable {
    let response: String?
    let history: [[String: AnyCodable]]?
    let error: String?
}

struct GatherBundle: Codable, Sendable {
    let mode: String?
    let original_prompt: String?
    let project_root: String?
    let project_type: String?
    let routing_decision: String?
    let packet_mode: String?
    let analysis_depth: String?
    let analysis_stages: [AnalysisStage]?
    let preflight: [String: AnyCodable]?
    let model_analysis: [String: AnyCodable]?
    let gather_reason: String?
    let confidence: Double?
    let git_status: String?
    let git_diff: String?
    let git_diff_summary: GitDiffSummary?
    let repo_index: RepoIndexSummary?
    let gathered_files: [String: GatheredFile]?
    let evidence_items: [EvidenceItem]?
    let error_lines: [String]?
    let context_summary: String?
    let open_questions: [String]?
    let assumptions: [String]?
    let token_budget: String?
    let estimated_tokens: Int?
    let omitted_context: [String: AnyCodable]?
    let codex_packet: String?
    let enriched_prompt: String?
    let error: String?
}

struct AnalysisStage: Codable, Sendable, Hashable {
    let stage: String?
    let model: String?
    let status: String?
    let error: String?
    let notes: [String]?
}

struct GitDiffSummary: Codable, Sendable, Hashable {
    let changed_files: [GitChangedFile]?
    let changed_file_count: Int?
    let hunks: [GitHunk]?
    let raw_diff_chars_omitted: Int?
}

struct GitChangedFile: Codable, Sendable, Hashable {
    let status: String?
    let path: String?
    let added: String?
    let removed: String?
}

struct GitHunk: Codable, Sendable, Hashable {
    let file: String?
    let start_line: Int?
    let end_line: Int?
    let added: Int?
    let removed: Int?
    let signals: [String]?
}

struct RepoIndexSummary: Codable, Sendable, Hashable {
    let cache_path: String?
    let indexed_file_count: Int?
    let changed_index_entries: Int?
}

struct GatheredFile: Codable, Sendable, Hashable {
    let tool: String?
    let preview: String?
}

struct EvidenceItem: Codable, Sendable, Hashable {
    let path: String?
    let kind: String?
    let reason: String?
    let preview: String?
    let start_line: Int?
    let end_line: Int?
    let symbols: [String]?
    let unity_refs: [String]?
}

struct RelayResponse: Codable, Sendable {
    let response: String?
    let source: String?
    let model: String?
    let routing_decision: String?
    let enriched_prompt: String?
    let codex_packet: String?
    let estimated_tokens: Int?
    let files_used: [String]?
    let errors_found: Int?
    let error: String?
}

struct AnyCodable: Codable, Sendable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self)                 { self.value = value }
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
    }
}

extension AnyCodable {
    var displayValue: String {
        if let value = value as? String { return value }
        if let value = value as? Int { return String(value) }
        if let value = value as? Double { return String(format: "%.2f", value) }
        if let value = value as? Bool { return value ? "true" : "false" }
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

// Structured log entry from ~/.soma/logs/soma_YYYYMMDD.jsonl
struct SomaLogEntry: Identifiable, Sendable {
    let id: UUID = UUID()
    let ts: String
    let event: String
    let tool: String?
    let method: String?
    let status: String
    let duration_ms: Double?
    let input_tokens: Int?
    let output_tokens: Int?
    let error: String?

    var displayName: String { tool ?? method ?? event }
    var totalTokens: Int { (input_tokens ?? 0) + (output_tokens ?? 0) }
    var isError: Bool { status == "error" }
    var isDegraded: Bool { status == "degraded" }
    var shortTime: String { String(ts.prefix(19)).replacingOccurrences(of: "T", with: " ") }

    init?(from dict: [String: Any]) {
        guard let ts = dict["ts"] as? String,
              let event = dict["event"] as? String else { return nil }
        self.ts = ts
        self.event = event
        self.tool = dict["tool"] as? String
        self.method = dict["method"] as? String
        self.status = (dict["status"] as? String) ?? "ok"
        self.duration_ms = dict["duration_ms"] as? Double
        self.input_tokens = dict["input_tokens"] as? Int
        self.output_tokens = dict["output_tokens"] as? Int
        self.error = dict["error"] as? String
    }
}

struct SomaToolStat: Identifiable, Sendable {
    let id: String
    let calls: Int
    let errors: Int
    let avgDuration: Double
    let totalTokens: Int

    var errorRate: Double { calls > 0 ? Double(errors) / Double(calls) : 0 }
}

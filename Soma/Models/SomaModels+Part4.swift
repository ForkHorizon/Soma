import Foundation
import SwiftUI

struct MCPSmokeReport: Codable, Sendable {
    let status: String?
    let generated_at: String?
    let project_root: String?
    let clients: [String: ClientConfigStatus]?
    let server: MCPSmokeServer?
    let initialize: MCPSmokeStep?
    let tools_list: MCPSmokeStep?
    let tool_results: [MCPSmokeStep]?
    let plugin_status: MCPSmokePluginStatus?
    let summary: MCPSmokeSummary?
    let issues: [String]?
    let log_file: String?
}

struct MCPSmokeServer: Codable, Sendable {
    let status: String?
    let tool_count: Int?
    let tool_names: [String]?
}

struct MCPSmokeStep: Codable, Sendable, Identifiable {
    var id: String { tool ?? output_hash ?? summary ?? "mcp-smoke-step" }
    let tool: String?
    let status: String?
    let result_status: String?
    let summary: String?
    let reason: String?
    let duration_ms: Double?
    let output_chars: Int?
    let output_hash: String?
    let tool_count: Int?
    let tool_names: [String]?
}

struct MCPSmokePluginStatus: Codable, Sendable {
    let unity_nexus: String?
    let nexus_connected: Bool?
    let nexus_project: String?
    let project_matches: Bool?
}

struct MCPSmokeSummary: Codable, Sendable {
    let tool_count: Int?
    let smoked_tools: Int?
    let skipped_tools: Int?
    let failed_tools: [String]?
    let config_degraded: [String]?
    let duration_ms: Double?
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
    let packet_tokens: Int?
    let budget_used_pct: Double?
    let saved_tokens: Int?
    let savings_pct: Double?
    let primary_metric: String?
    let operation_saved_tokens: Int?
    let operation_savings_pct: Double?
    let operation_baseline_tokens: Int?
    let soma_response_tokens: Int?
    let estimated_context_saved_tokens: Int?
    let estimated_context_reduction_pct: Double?
    let estimated_context_baseline_tokens: Int?
    let baseline_type: String?
    let token_estimator: String?
    let client: String?
    let run_id: String?
    let task_id: String?
    let workflow: String?
    let prompt_hash: String?
    let packet_hash: String?
    let local_model_provider: String?
    let local_model: String?
    let local_model_stage: String?
    let local_model_json_mode: Bool?
    let local_model_num_predict: Int?
    let local_model_tool_count: Int?
    let local_model_message_count: Int?
    let local_ai_policy: String?
    let local_ai_call_count: Int?
    let local_ai_input_tokens: Int?
    let local_ai_output_tokens: Int?
    let local_ai_latency_ms: Double?
    let candidate_tokens_before: Int?
    let candidate_tokens_after: Int?
    let local_ai_net_savings_tokens: Int?
    let output_truncated: Bool?
    let omitted_output_tokens: Int?
    let source_language: String?
    let translation_status: String?
    let translation_engine: String?
    let prompt_saved_tokens: Int?
    let prompt_savings_pct: Double?
    let protected_spans_count: Int?
    let error: String?
    let rawPayload: String?

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
        self.packet_tokens = SomaLogEntry.intValue(dict["packet_tokens"])
        self.budget_used_pct = SomaLogEntry.doubleValue(dict["budget_used_pct"])
        self.saved_tokens = SomaLogEntry.intValue(dict["saved_tokens"])
        self.savings_pct = SomaLogEntry.doubleValue(dict["savings_pct"])
        self.primary_metric = dict["primary_metric"] as? String
        self.operation_saved_tokens = SomaLogEntry.intValue(dict["operation_saved_tokens"])
        self.operation_savings_pct = SomaLogEntry.doubleValue(dict["operation_savings_pct"])
        self.operation_baseline_tokens = SomaLogEntry.intValue(dict["operation_baseline_tokens"])
        self.soma_response_tokens = SomaLogEntry.intValue(dict["soma_response_tokens"])
        self.estimated_context_saved_tokens = SomaLogEntry.intValue(dict["estimated_context_saved_tokens"])
        self.estimated_context_reduction_pct = SomaLogEntry.doubleValue(dict["estimated_context_reduction_pct"])
        self.estimated_context_baseline_tokens = SomaLogEntry.intValue(dict["estimated_context_baseline_tokens"])
        self.baseline_type = dict["baseline_type"] as? String
        self.token_estimator = dict["token_estimator"] as? String
        self.client = dict["client"] as? String
        self.run_id = dict["run_id"] as? String
        self.task_id = dict["task_id"] as? String
        self.workflow = dict["workflow"] as? String
        self.prompt_hash = dict["prompt_hash"] as? String
        self.packet_hash = dict["packet_hash"] as? String
        self.local_model_provider = dict["local_model_provider"] as? String
        self.local_model = dict["local_model"] as? String
        self.local_model_stage = dict["local_model_stage"] as? String
        self.local_model_json_mode = dict["local_model_json_mode"] as? Bool
        self.local_model_num_predict = SomaLogEntry.intValue(dict["local_model_num_predict"])
        self.local_model_tool_count = SomaLogEntry.intValue(dict["local_model_tool_count"])
        self.local_model_message_count = SomaLogEntry.intValue(dict["local_model_message_count"])
        self.local_ai_policy = dict["local_ai_policy"] as? String
        self.local_ai_call_count = SomaLogEntry.intValue(dict["local_ai_call_count"])
        self.local_ai_input_tokens = SomaLogEntry.intValue(dict["local_ai_input_tokens"])
        self.local_ai_output_tokens = SomaLogEntry.intValue(dict["local_ai_output_tokens"])
        self.local_ai_latency_ms = SomaLogEntry.doubleValue(dict["local_ai_latency_ms"])
        self.candidate_tokens_before = SomaLogEntry.intValue(dict["candidate_tokens_before"])
        self.candidate_tokens_after = SomaLogEntry.intValue(dict["candidate_tokens_after"])
        self.local_ai_net_savings_tokens = SomaLogEntry.intValue(dict["local_ai_net_savings_tokens"])
        self.output_truncated = dict["output_truncated"] as? Bool
        self.omitted_output_tokens = SomaLogEntry.intValue(dict["omitted_output_tokens"])
        self.source_language = dict["source_language"] as? String
        self.translation_status = dict["translation_status"] as? String
        self.translation_engine = dict["translation_engine"] as? String
        self.prompt_saved_tokens = SomaLogEntry.intValue(dict["prompt_saved_tokens"])
        self.prompt_savings_pct = SomaLogEntry.doubleValue(dict["prompt_savings_pct"])
        self.protected_spans_count = SomaLogEntry.intValue(dict["protected_spans_count"])
        self.error = dict["error"] as? String
        self.rawPayload = SomaLogEntry.prettyPayload(from: dict)
    }

    static func prettyPayload(from dict: [String: Any]) -> String? {
        let redacted = redactSensitiveValues(in: dict)
        guard JSONSerialization.isValidJSONObject(redacted),
              let data = try? JSONSerialization.data(withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    static func redactSensitiveValues(in value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var output: [String: Any] = [:]
            for (key, nestedValue) in dict {
                let lower = key.lowercased()
                if lower.contains("token") || lower.contains("secret") || lower.contains("password") || lower.contains("apikey") || lower.contains("api_key") || lower.contains("authorization") {
                    output[key] = "[REDACTED]"
                } else {
                    output[key] = redactSensitiveValues(in: nestedValue)
                }
            }
            return output
        }
        if let array = value as? [Any] {
            return array.map { redactSensitiveValues(in: $0) }
        }
        return value
    }

    static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        return nil
    }

    static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }
}

struct SomaLocalModelStat: Identifiable, Sendable {
    let id: String
    let calls: Int
    let errors: Int
    let avgDuration: Double
    let totalTokens: Int
    let stages: [String: Int]
    let models: [String: Int]

    var errorRate: Double { calls > 0 ? Double(errors) / Double(calls) : 0 }
}

struct SomaToolStat: Identifiable, Sendable {
    let id: String
    let calls: Int
    let errors: Int
    let avgDuration: Double
    let totalTokens: Int
    let totalSavedTokens: Int
    let avgSavingsPct: Double?
    let totalOperationSavedTokens: Int
    let avgOperationSavingsPct: Double?
    let totalEstimatedContextSavedTokens: Int
    let avgEstimatedContextReductionPct: Double?

    var errorRate: Double { calls > 0 ? Double(errors) / Double(calls) : 0 }
}

struct TokenBenchmarkReport: Codable, Sendable {
    let status: String?
    let generated_at: String?
    let model_profile: String?
    let budget: String?
    let baseline: String?
    let summary: TokenBenchmarkSummary?
    let results: [TokenBenchmarkResult]?
}

import Combine
import Foundation

struct Stage8AuditSample: Codable, Identifiable {
    let sampleID: Int
    let file: String
    let audioPath: String
    let proposedText: String
    let tier: String
    let confirmedBy: String
    var id: Int { sampleID }

    enum CodingKeys: String, CodingKey {
        case sampleID = "sample_id", file, audioPath = "audio_path"
        case proposedText = "proposed_text", tier, confirmedBy = "confirmed_by"
    }
}

struct Stage8AuditDecision: Codable {
    let sampleID: Int
    let file: String
    let status: String
    let auditedText: String
    let notes: String
    let decidedAt: Date

    enum CodingKeys: String, CodingKey {
        case sampleID = "sample_id", file, status
        case auditedText = "audited_text", notes
        case decidedAt = "decided_at"
    }
}

@MainActor
final class Stage8AuditStore: ObservableObject {
    @Published private(set) var samples: [Stage8AuditSample] = []
    @Published private(set) var decisions: [Int: Stage8AuditDecision] = [:]
    @Published private(set) var failure: String?

    static var experimentsDirectory: URL {
        GroundTruthRunner.outputDirectory.appendingPathComponent("experiments", isDirectory: true)
    }

    private let manifestURL: URL
    private let decisionsURL: URL

    init(manifestURL: URL? = nil, decisionsURL: URL? = nil) {
        self.manifestURL = manifestURL ?? Self.experimentsDirectory.appendingPathComponent("stage8-auto-audit-100.jsonl")
        self.decisionsURL = decisionsURL ?? Self.experimentsDirectory.appendingPathComponent("stage8-auto-audit-decisions.jsonl")
    }

    var pending: [Stage8AuditSample] { samples.filter { decisions[$0.sampleID] == nil } }
    var reviewedCount: Int { decisions.count }

    func load() {
        do {
            samples = try decodeLines(Stage8AuditSample.self, from: manifestURL)
            decisions = [:]
            for decision in try decodeLines(Stage8AuditDecision.self, from: decisionsURL) {
                decisions[decision.sampleID] = decision
            }
            failure = nil
        } catch {
            samples = []
            decisions = [:]
            failure = error.localizedDescription
        }
    }

    func record(_ sample: Stage8AuditSample, status: String, auditedText: String, notes: String) {
        let decision = Stage8AuditDecision(
            sampleID: sample.sampleID, file: sample.file, status: status,
            auditedText: auditedText, notes: notes, decidedAt: Date())
        do {
            try FileManager.default.createDirectory(at: decisionsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let line = try String(decoding: encoder.encode(decision), as: UTF8.self) + "\n"
            if FileManager.default.fileExists(atPath: decisionsURL.path) {
                let handle = try FileHandle(forWritingTo: decisionsURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line.data(using: .utf8)!)
                try handle.close()
            } else {
                try line.write(to: decisionsURL, atomically: true, encoding: .utf8)
            }
            decisions[sample.sampleID] = decision
        } catch {
            failure = "Could not save audit decision: \(error.localizedDescription)"
        }
    }

    private func decodeLines<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try decoder.decode(T.self, from: Data($0.utf8))
        }
    }
}

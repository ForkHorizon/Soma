import Foundation

struct Layer1ModelRun: Codable, Hashable, Identifiable {
    let id: String
    let audioID: String
    let modelID: String
    let model: String
    let family: String
    let version: String
    let configuration: [String: String]
    let startedAt: Date?
    let finishedAt: Date?
    let duration: Double?
    let attempt: Int
    var status: Layer1ModelRunStatus
    var rawResponse: String?
    var text: String?
    var wordTimestamps: [Layer1WordTimestamp]
    var error: String?
}

struct Layer1RunCompletion: Hashable {
    let status: Layer1ModelRunStatus
    let version: String
    let rawResponse: String
    let text: String?
    let timestamps: [Layer1WordTimestamp]
    let error: String?
    let duration: Double
}

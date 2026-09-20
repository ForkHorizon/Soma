import Foundation

struct Layer1State: Codable {
    static let currentSchemaVersion = 1
    var schemaVersion = currentSchemaVersion
    var createdAt = Date()
    var updatedAt = Date()
    var batches: [Layer1Batch] = []
    var files: [Layer1AudioFile] = []
    var modelRuns: [Layer1ModelRun] = []
    var segments: [Layer1Segment] = []
    var lastReviewSegmentID: String?
}

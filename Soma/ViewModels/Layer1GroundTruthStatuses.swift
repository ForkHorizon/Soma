import Foundation

enum Layer1BatchStatus: String, Codable, CaseIterable {
    case queued, running, completed, partial, failed
}
enum Layer1ModelRunStatus: String, Codable { case queued, running, completed, failed }

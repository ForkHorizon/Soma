import Foundation

/// Durable Layer 1 model runs and human review state.
final class Layer1GroundTruthStore {
    static var directory: URL { GroundTruthPaths.activeLayer1 }

    let directory: URL
    var state: Layer1State

    init(directory: URL = Layer1GroundTruthStore.directory) {
        self.directory = directory
        self.state = Self.loadState(from: directory) ?? Layer1State()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        bootstrapCommandConfiguration()
        recoverInterruptedRuns()
        retryLegacyEnvironmentFailures()
        normalizePartiallyQueuedBatches()
        save()
    }

    var stateURL: URL { directory.appendingPathComponent("state.json") }
    var historyURL: URL { directory.appendingPathComponent("history.jsonl") }
    var commandConfigurationURL: URL { directory.appendingPathComponent("model_commands.json") }

    var requiredModelIDs: Set<String> {
        Set(Layer1ModelSpec.catalog.filter { !$0.optional }.map(\.id))
    }
    var allModelIDs: [String] { Layer1ModelSpec.catalog.map(\.id) }
}

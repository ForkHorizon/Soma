import Foundation

/// Durable Layer 1 model runs and human review state.
final class Layer1GroundTruthStore {
    static var directory: URL { GroundTruthPaths.activeLayer1 }

    let directory: URL
    var state: Layer1State
    private(set) var canPersistState = true
    private(set) var stateLoadError: String?
    var statePersistenceError: String? = nil
    var stage2StorageError: String?

    init(directory: URL = Layer1GroundTruthStore.directory) {
        self.directory = directory
        let stateURL = directory.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: stateURL.path) {
            do {
                self.state = try Self.loadState(from: directory)
                self.stateLoadError = nil
            } catch {
                self.state = Layer1State()
                self.canPersistState = false
                self.stateLoadError = "Layer 1 state could not be loaded: \(error.localizedDescription)"
            }
        } else {
            self.state = Layer1State()
            self.stateLoadError = nil
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        bootstrapCommandConfiguration()
        recoverInterruptedRuns()
        retryLegacyEnvironmentFailures()
        normalizePartiallyQueuedBatches()
        rebuildPendingSegmentsIfNeeded()
        if canPersistState { save() }
    }

    var stateURL: URL { directory.appendingPathComponent("state.json") }
    var historyURL: URL { directory.appendingPathComponent("history.jsonl") }
    var commandConfigurationURL: URL { directory.appendingPathComponent("model_commands.json") }

    var requiredModelIDs: Set<String> {
        Set(Layer1ModelSpec.catalog.filter { !$0.optional }.map(\.id))
    }

    var activeModelSpecs: [Layer1ModelSpec] {
        Layer1ModelSpec.catalog.filter { spec in
            !spec.optional || !commandConfiguration(for: spec.id).command.isEmpty
        }
    }

    var activeModelIDs: Set<String> { Set(activeModelSpecs.map(\.id)) }
}

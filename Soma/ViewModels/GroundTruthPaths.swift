import Foundation

/// One storage contract for the historical Ground Truth pipeline and the new
/// Layer-1 cycle. The paths are deliberately namespaced so old artifacts can
/// be inspected without becoming inputs to a new run.
enum GroundTruthPaths {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soma/GroundTruth", isDirectory: true)
    }

    static var active: URL { root.appendingPathComponent("active", isDirectory: true) }
    static var activeHuman: URL { active.appendingPathComponent("human", isDirectory: true) }
    static var activeEvidence: URL { active.appendingPathComponent("evidence", isDirectory: true) }
    static var activeExperiments: URL { active.appendingPathComponent("experiments", isDirectory: true) }
    static var activeLayer1: URL { active.appendingPathComponent("layer1", isDirectory: true) }
    static var activeLayer2: URL { active.appendingPathComponent("layer2", isDirectory: true) }
    static var activeLayer2Preferred: URL { activeLayer2.appendingPathComponent("preferred.jsonl") }
    static var activeHumanGold: URL { activeHuman.appendingPathComponent("gold.jsonl") }

    /// The pre-structure workspace is read only by historical Stage-5/7/8 UI
    /// and scripts. It is never an input to the active Layer-1 cycle.
    static var legacyRoot: URL {
        root.appendingPathComponent("archives/pre-structure-v1/root", isDirectory: true)
    }

    static var legacyExperiments: URL {
        legacyRoot.appendingPathComponent("experiments", isDirectory: true)
    }
}

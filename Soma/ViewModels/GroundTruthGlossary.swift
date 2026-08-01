import Foundation

/// Term pairs the listener has confirmed against the audio, plus the reference
/// transcripts they have settled by hand.
///
/// Nothing here is inferred. GigaAM writing "юнити" where Whisper wrote "unity"
/// only *looks* like the same word — the consensus never forgives it until this
/// file says it may, because a rule based on script alone would hide exactly the
/// technical terms the corpus is full of.
enum GroundTruthGlossary {
    static var url: URL {
        GroundTruthRunner.outputDirectory.appendingPathComponent("glossary.json")
    }

    /// Maps what GigaAM heard to the spellings accepted for it.
    static func load() -> [String: [String]] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
        else { return [:] }
        return object
    }

    static func contains(heard: String, written: String) -> Bool {
        load()[heard]?.contains(written) ?? false
    }

    static func confirm(heard: String, written: String) {
        var glossary = load()
        var spellings = glossary[heard] ?? []
        guard !spellings.contains(written) else { return }
        spellings.append(written)
        glossary[heard] = spellings
        save(glossary)
    }

    static func forget(heard: String, written: String) {
        var glossary = load()
        guard var spellings = glossary[heard] else { return }
        spellings.removeAll { $0 == written }
        glossary[heard] = spellings.isEmpty ? nil : spellings
        save(glossary)
    }

    private static func save(_ glossary: [String: [String]]) {
        try? FileManager.default.createDirectory(at: GroundTruthRunner.outputDirectory,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: glossary,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Reference transcripts settled by hand, appended one JSON object per line so a
/// crash mid-session cannot take the earlier decisions with it.
enum GroundTruthGold {
    static var url: URL {
        GroundTruthRunner.outputDirectory.appendingPathComponent("gold.jsonl")
    }

    static func settled() -> Set<String> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object["file"] as? String
        })
    }

    static func write(file: String, text: String, source: String) {
        let row: [String: Any] = ["file": file, "text": text, "source": source]
        guard let data = try? JSONSerialization.data(withJSONObject: row),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line += "\n"
        try? FileManager.default.createDirectory(at: GroundTruthRunner.outputDirectory,
                                                 withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

import Foundation

private struct Layer1SegmentSeed {
    let audioID: String
    let start: Double
    let end: Double
    let range: Range<Int>?
    let suggestions: [String: Layer1ModelSuggestion]
    let needsReview: Bool
    let algorithmVersion: String
}

extension Layer1GroundTruthStore {
    static func makeSegments(
        audioID: String, duration: Double, words: [Layer1WordTimestamp],
        suggestions: [String: Layer1ModelSuggestion], algorithmVersion: String = "layer1-seg-v2"
    ) -> [Layer1Segment] {
        let clean = words.filter { $0.end > $0.start && !$0.word.isEmpty }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        if clean.isEmpty {
            return fallbackSegments(
                audioID: audioID, duration: duration, suggestions: suggestions,
                algorithmVersion: algorithmVersion)
        }
        var groups: [(Int, Int)] = []
        var start = 0
        let maximumWords = 9
        for index in clean.indices {
            let count = index - start + 1
            let pause = index + 1 < clean.count ? clean[index + 1].start - clean[index].end : .infinity
            if count >= maximumWords || (count >= 3 && pause >= 0.45) {
                groups.append((start, index + 1))
                start = index + 1
            }
        }
        if start < clean.count { groups.append((start, clean.count)) }
        return groups.enumerated().map { number, group in
            let left = number == 0 ? 0 : boundary(after: clean[group.0 - 1], before: clean[group.0])
            let right =
                number == groups.count - 1
                ? max(duration, clean[group.1 - 1].end)
                : boundary(after: clean[group.1 - 1], before: clean[group.1])
            return segment(
                Layer1SegmentSeed(
                    audioID: audioID, start: left, end: max(left + 0.05, right), range: group.0..<group.1,
                    suggestions: suggestions, needsReview: false,
                    algorithmVersion: algorithmVersion + ":\(number)"))
        }
    }

    private static func fallbackSegments(
        audioID: String, duration: Double, suggestions: [String: Layer1ModelSuggestion],
        algorithmVersion: String
    ) -> [Layer1Segment] {
        let end = max(duration, 0.1)
        let count = max(1, Int(ceil(end / 6.0)))
        return (0..<count).map { index in
            let start = end * Double(index) / Double(count)
            let finish = end * Double(index + 1) / Double(count)
            return segment(
                Layer1SegmentSeed(
                    audioID: audioID, start: start, end: finish, range: nil, suggestions: suggestions,
                    needsReview: false, algorithmVersion: "\(algorithmVersion):fallback:\(index)"))
        }
    }

    private static func boundary(
        after previous: Layer1WordTimestamp, before next: Layer1WordTimestamp
    ) -> Double {
        let lower = min(previous.end, next.start)
        let upper = max(previous.end, next.start)
        return (lower + upper) / 2
    }

    func rebuildPendingSegmentsIfNeeded() {
        let audioIDs = Set(
            state.segments.filter {
                $0.decision.status == .pending
                    && !$0.segmentationAlgorithmVersion.hasPrefix("layer1-seg-v2")
            }.map(\.audioID))
        for audioID in audioIDs where status(for: audioID) == .completed {
            let segments = state.segments.filter { $0.audioID == audioID }
            guard segments.allSatisfy({ $0.decision.status == .pending }) else { continue }
            state.segments.removeAll { $0.audioID == audioID }
            buildSegmentsIfReady(audioID: audioID)
        }
    }

    private static func segment(_ seed: Layer1SegmentSeed) -> Layer1Segment {
        let ids = Layer1ModelSpec.catalog.map(\.id)
        let offset = abs(seed.audioID.hashValue) % max(ids.count, 1)
        let order = Array(ids[offset...] + ids[..<offset])
        return Layer1Segment(
            id: "\(seed.audioID)#\(seed.start)#\(seed.end)", audioID: seed.audioID,
            start: seed.start, end: seed.end, segmentationAlgorithmVersion: seed.algorithmVersion,
            sourceWordRange: seed.range, modelSuggestions: seed.suggestions, proposalOrder: order,
            segmentationNeedsReview: seed.needsReview,
            decision: Layer1SegmentDecision(
                status: .pending, text: nil, normalizedText: nil, action: nil,
                sourceModelID: nil, createdAt: nil, updatedAt: nil))
    }

    func buildSegmentsIfReady(audioID: String) {
        guard !state.segments.contains(where: { $0.audioID == audioID }), let file = file(for: audioID)
        else { return }
        let runs = runs(for: audioID)
        let activeRuns = runs.filter { activeModelIDs.contains($0.modelID) }
        guard activeRuns.count == activeModelIDs.count,
            activeRuns.allSatisfy({ $0.status == .completed })
        else {
            return
        }
        let timed = activeRuns.first(where: { !$0.wordTimestamps.isEmpty })?.wordTimestamps ?? []
        let base = Self.makeSegments(
            audioID: audioID, duration: file.duration, words: timed, suggestions: [:])
        state.segments.append(
            contentsOf: base.map { segment in
                var result = segment
                result.modelSuggestions = Dictionary(
                    uniqueKeysWithValues: activeRuns.compactMap { run in
                        let scoped: String?
                        if !run.wordTimestamps.isEmpty {
                            scoped = run.wordTimestamps.filter {
                                $0.end > segment.start && $0.start < segment.end
                            }
                            .map(\.word).joined(separator: " ")
                        } else if run.status == .failed {
                            scoped = nil
                        } else {
                            return nil
                        }
                        return (
                            run.modelID,
                            Layer1ModelSuggestion(
                                modelID: run.modelID, model: run.model, status: run.status,
                                text: scoped, reviewText: scoped.map(Self.normalizeForReview),
                                error: run.error, runID: run.id)
                        )
                    })
                return result
            })
    }
}

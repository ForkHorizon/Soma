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
        suggestions: [String: Layer1ModelSuggestion], algorithmVersion: String = "layer1-seg-v1"
    ) -> [Layer1Segment] {
        let clean = words.filter { $0.end > $0.start && !$0.word.isEmpty }
        if clean.isEmpty {
            return [
                segment(
                    Layer1SegmentSeed(
                        audioID: audioID, start: 0, end: max(duration, 0.1), range: nil,
                        suggestions: suggestions, needsReview: duration > 7, algorithmVersion: algorithmVersion)
                )
            ]
        }
        var groups: [(Int, Int)] = []
        var start = 0
        for index in clean.indices {
            let count = index - start + 1
            let pause = index + 1 < clean.count ? clean[index + 1].start - clean[index].end : .infinity
            if count >= 7 || (count >= 3 && pause >= 0.45) {
                groups.append((start, index + 1))
                start = index + 1
            }
        }
        if start < clean.count { groups.append((start, clean.count)) }
        return groups.enumerated().map { number, group in
            let first = clean[group.0]
            let last = clean[group.1 - 1]
            let left = max(0, first.start - 0.15)
            let right = min(max(duration, last.end), last.end + 0.15)
            return segment(
                Layer1SegmentSeed(
                    audioID: audioID, start: left, end: max(left + 0.05, right), range: group.0..<group.1,
                    suggestions: suggestions, needsReview: group.1 - group.0 > 7,
                    algorithmVersion: algorithmVersion + ":\(number)"))
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
        guard runs.count == allModelIDs.count, runs.allSatisfy({ $0.status == .completed }) else {
            return
        }
        let hasUnmapped = runs.contains {
            $0.status == .completed && !($0.text ?? "").isEmpty && $0.wordTimestamps.isEmpty
        }
        let timed =
            hasUnmapped ? [] : (runs.first(where: { !$0.wordTimestamps.isEmpty })?.wordTimestamps ?? [])
        let base = Self.makeSegments(
            audioID: audioID, duration: file.duration, words: timed, suggestions: [:])
        state.segments.append(
            contentsOf: base.map { segment in
                var result = segment
                result.modelSuggestions = Dictionary(
                    uniqueKeysWithValues: runs.map { run in
                        let scoped: String?
                        if !run.wordTimestamps.isEmpty {
                            let timed = run.wordTimestamps.filter {
                                $0.end > segment.start && $0.start < segment.end
                            }
                            .map(\.word).joined(separator: " ")
                            scoped = timed.isEmpty ? run.text : timed
                        } else {
                            scoped = run.text
                        }
                        return (
                            run.modelID,
                            Layer1ModelSuggestion(
                                modelID: run.modelID, model: run.model, status: run.status,
                                text: scoped, error: run.error, runID: run.id)
                        )
                    })
                return result
            })
    }
}

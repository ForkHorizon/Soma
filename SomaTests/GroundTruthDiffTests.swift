import XCTest
@testable import Soma

final class GroundTruthDiffTests: XCTestCase {
    /// The engines differ on punctuation and case for every word — GigaAM
    /// writes lowercase and unpunctuated — so a raw comparison would paint the
    /// whole transcript and point at nothing.
    func testPunctuationAndCaseAloneAreNotADisagreement() {
        let marked = GroundTruthDiff.mark([
            ("gigaam", "смотри ситуация что мы бросаем видео"),
            ("w-prompt", "Смотри, ситуация, что мы бросаем видео."),
        ])
        XCTAssertEqual(marked["w-prompt"]?.differing, [])
        XCTAssertEqual(marked["gigaam"]?.differing, [])
    }

    /// The real case from the corpus: one term read two ways, three times over.
    func testOnlyTheDisputedWordIsMarked() {
        let marked = GroundTruthDiff.mark([
            ("gigaam", "преобразование с аудио в текст"),
            ("w-greedy", "преобразование с audi в текст"),
        ])
        XCTAssertEqual(marked["w-greedy"]?.differing, [2], "only 'audi' should be marked")
        XCTAssertEqual(marked["gigaam"]?.differing, [2], "'аудио' must be marked on the anchor too")
    }

    /// The anchor is what everything else is compared against, so without
    /// folding the other side's differences back into it, the one transcript a
    /// reviewer reads first would be the one place a disagreement is invisible.
    func testTheAnchorShowsItsOwnDisagreements() {
        let marked = GroundTruthDiff.mark([
            ("gigaam", "раз два три"),
            ("w-greedy", "раз пять три"),
            ("fw-beam", "раз пять три"),
        ])
        XCTAssertEqual(marked["gigaam"]?.differing, [1])
    }

    func testAnEmptyCandidateIsHandled() {
        let marked = GroundTruthDiff.mark([("gigaam", ""), ("w-greedy", "привет мир")])
        XCTAssertEqual(marked["gigaam"]?.words, [])
        XCTAssertEqual(marked["w-greedy"]?.differing, [0, 1], "nothing to agree with, so all of it differs")
    }

    /// Issue #0070/#61/#0083: key() used to strip +/#/* like any other
    /// punctuation, so "C++", "C#" and "C" all normalized to "c" and a real
    /// disagreement on a technical term never reached the reviewer — the two
    /// candidates below differ ONLY in those symbols.
    func testATechnicalTermDisagreementIsNotHiddenByNormalization() {
        let marked = GroundTruthDiff.mark([
            ("gigaam", "мы пишем на c"),
            ("w-greedy", "мы пишем на C++"),
        ])
        XCTAssertEqual(marked["w-greedy"]?.differing, [3], "'C++' must be marked as different from 'c'")
        XCTAssertEqual(marked["gigaam"]?.differing, [3], "'c' must be marked on the anchor too")
    }
}

extension GroundTruthDiffTests {
    /// Three of the eight engines routinely land on the same string, so the
    /// reviewer reads the same paragraph three times before reaching a
    /// difference.
    func testIdenticalTranscriptsCollapseIntoOneEntry() {
        let groups = GroundTruthDiff.group([
            ("gigaam", "привет мир"), ("gigaam-ctc", "привет мир"),
            ("w-greedy", "привет мор"), ("fw-beam", "привет мир"),
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].names, ["gigaam", "gigaam-ctc", "fw-beam"])
        XCTAssertEqual(groups[1].names, ["w-greedy"])
        XCTAssertEqual(groups[0].text, "привет мир", "first occurrence keeps its position")
    }

    /// Three cards reading the same sentence with different commas is three
    /// readings of one thing. WER strips punctuation, so which one is adopted
    /// changes nothing that gets measured.
    func testPunctuationAloneDoesNotSplitACard() {
        let groups = GroundTruthDiff.group([
            ("gigaam", "хотя с другой стороны я не знаю"),
            ("w-greedy", "Хотя с другой стороны я не знаю."),
            ("w-sample", "Хотя, с другой стороны, я не знаю."),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(
            groups[0].text, "Хотя, с другой стороны, я не знаю.",
            "the most punctuated variant is the one worth keeping")
    }

    func testDifferentWordsStillSplit() {
        let groups = GroundTruthDiff.group([
            ("gigaam", "привет мир"), ("w-greedy", "привет мор"),
        ])
        XCTAssertEqual(groups.count, 2)
    }
}

final class GroundTruthQueueTests: XCTestCase {
    private func verdict(_ file: String, edits: Int) -> GroundTruthVerdict {
        GroundTruthVerdict(
            file: file, status: "review", reason: "", edits: edits,
            candidates: [:], terms: [], spots: [])
    }

    /// A file only becomes a gold row once all of its operations are settled, so
    /// the cheapest file goes first and its own operations stay chronological.
    func testTheCheapestRecordingComesFirstAndStaysChronological() {
        let expensive = GroundTruthVerdict(
            file: "rec-100.wav", status: "review", reason: "", edits: 20,
            candidates: ["w-greedy": "a b c"], terms: [], spots: [],
            operations: [
                operation("late", 8...9), operation("early", 1...2),
            ])
        let cheap = GroundTruthVerdict(
            file: "rec-200.wav", status: "review", reason: "", edits: 0,
            candidates: ["w-greedy": "a"], terms: [], spots: [], operations: [operation("only", 2...3)])
        XCTAssertEqual(
            GroundTruthRunner.operationQueue([expensive, cheap]).map { "\($0.verdict.file):\($0.operation.id)" },
            ["rec-200.wav:only", "rec-100.wav:early", "rec-100.wav:late"])
    }

    /// Cheapest-first alone would fill the corpus with short easy audio, so the
    /// expensive half is dealt in between: stopping early still spans both.
    func testCheapAndExpensiveRecordingsAlternate() {
        let files = (1...4).map { count in
            GroundTruthVerdict(
                file: "rec-\(100 * count).wav", status: "review", reason: "", edits: 0,
                candidates: ["w-greedy": "a"], terms: [], spots: [],
                operations: (0..<count).map { operation("op\($0)", Double($0)...Double($0 + 1)) })
        }
        XCTAssertEqual(
            Set(GroundTruthRunner.operationQueue(files).prefix(3).map(\.verdict.file)),
            ["rec-100.wav", "rec-300.wav"], "one operation from the cheapest, then a hard one")
    }

    /// One reading left means the decodes already settled it; showing it would
    /// ask the listener to confirm a unanimous vote.
    func testAnOperationWithNothingToChooseIsNotShown() {
        let verdict = GroundTruthVerdict(
            file: "rec-100.wav", status: "review", reason: "", edits: 1,
            candidates: ["w-greedy": "a"], terms: [], spots: [],
            operations: [
                operation("settled", 1...2, alternatives: 1),
                operation("open", 3...4),
            ])
        XCTAssertEqual(GroundTruthRunner.operationQueue([verdict]).map(\.operation.id), ["open"])
    }

    private func operation(
        _ id: String, _ seconds: ClosedRange<Double>,
        alternatives: Int = 2
    ) -> GroundTruthReviewOperation {
        GroundTruthReviewOperation(
            id: id, signature: id, anchor: 0..<1, seconds: seconds,
            contextBefore: "", contextAfter: "",
            alternatives: (0..<alternatives).map {
                GroundTruthOperationAlternative(names: ["engine\($0)"], text: "text\($0)")
            })
    }
}

/// The Swift port of Scripts/ground_truth_text.normalize (issue #0083):
/// GroundTruthDiff.key and GroundTruthReviewView.termPairs both delegate here,
/// so this is the one place that has to match the Python side.
final class GroundTruthGlossaryNormalizeTests: XCTestCase {
    func testBridgesTheTwoEnginesSurfaceForms() {
        XCTAssertEqual(
            GroundTruthGlossary.normalize("Привет, ёжик!"),
            GroundTruthGlossary.normalize("привет ежик"))
    }

    func testKeepsCPlusPlusAndCSharpApartFromC() {
        XCTAssertEqual(GroundTruthGlossary.normalize("C++"), "c++")
        XCTAssertEqual(GroundTruthGlossary.normalize("C#"), "c#")
        XCTAssertEqual(GroundTruthGlossary.normalize("C"), "c")
    }

    func testStandaloneSymbolsStillStrip() {
        XCTAssertEqual(GroundTruthGlossary.normalize("5 + 3"), "5 3")
    }
}

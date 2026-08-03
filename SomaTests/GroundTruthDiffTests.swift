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

    /// Punctuation is not cosmetic here: whichever transcript is adopted
    /// becomes the reference, and its punctuation goes with it.
    func testPunctuationDifferencesStaySeparateChoices() {
        let groups = GroundTruthDiff.group([
            ("gigaam", "привет мир"), ("w-prompt", "Привет, мир."),
        ])
        XCTAssertEqual(groups.count, 2)
    }
}

final class GroundTruthQueueTests: XCTestCase {
    private func verdict(_ file: String, edits: Int) -> GroundTruthVerdict {
        GroundTruthVerdict(file: file, status: "review", reason: "", edits: edits,
                           candidates: [:], terms: [], spots: [])
    }

    /// Sorting by cost alone put every one- and two-word case first, so a
    /// listener who stopped partway — the realistic outcome at 589 files —
    /// ended up with a sample of only easy recordings, which is exactly where
    /// every decode configuration looks the same.
    func testTheQueueStaysRepresentativeWhereverYouStop() {
        let items = (1...5).flatMap { band in
            (1...4).map { verdict("b\(band)-\($0).wav", edits: [1, 2, 4, 8, 20][band - 1]) }
        }
        let queue = GroundTruthRunner.stratified(items)
        let firstRound = Set(queue.prefix(5).map { GroundTruthRunner.band($0.edits) })
        XCTAssertEqual(firstRound, [0, 1, 2, 3, 4], "the first five must span every band")
        XCTAssertEqual(queue.count, items.count, "nothing may be dropped")
        XCTAssertEqual(Set(queue.map(\.file)).count, items.count, "nor duplicated")
    }

    /// Bands run out at different rates; the rest must still all appear.
    func testUnevenBandsDrainWithoutLoss() {
        let items = [verdict("a.wav", edits: 1), verdict("b.wav", edits: 1),
                     verdict("c.wav", edits: 1), verdict("d.wav", edits: 20)]
        let queue = GroundTruthRunner.stratified(items)
        XCTAssertEqual(queue.map(\.file), ["a.wav", "d.wav", "b.wav", "c.wav"])
    }
}

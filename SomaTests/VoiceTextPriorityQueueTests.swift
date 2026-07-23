import XCTest
@testable import Soma

@MainActor
final class VoiceTextPriorityQueueTests: XCTestCase {
    func testTranslationSplitPreservesPunctuationAndOrder() {
        let source = "First sentence. Second question? Third answer!\nFourth line."
        let parts = VoiceTextPriorityQueue.splitForTranslation(source, limit: 24)
        let reconstructed = parts.joined(separator: " ")

        XCTAssertEqual(reconstructed.filter { !$0.isWhitespace }, source.filter { !$0.isWhitespace })
        XCTAssertTrue(reconstructed.contains("."))
        XCTAssertTrue(reconstructed.contains("?"))
        XCTAssertTrue(reconstructed.contains("!"))
    }

    func testTranslationSplitBoundsLongUnpunctuatedText() {
        let source = String(repeating: "word ", count: 2_000)
        let parts = VoiceTextPriorityQueue.splitForTranslation(source, limit: 250)

        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 250 })
        XCTAssertEqual(parts.joined(separator: " ").split(whereSeparator: \.isWhitespace).count, 2_000)
    }
}

import XCTest
@testable import Soma

final class GlobalVoiceQueueTests: XCTestCase {
    func testFIFODequeuesInCaptureOrder() {
        var queue = GlobalVoiceFIFO<Int>()
        for value in 1...10 { queue.enqueue(value) }

        XCTAssertEqual((1...10).compactMap { _ in queue.dequeue() }, Array(1...10))
        XCTAssertTrue(queue.isEmpty)
    }

    func testFIFOStaysOrderedWhenNewWorkArrivesDuringProcessing() {
        var queue = GlobalVoiceFIFO<String>()
        queue.enqueue("first")
        XCTAssertEqual(queue.dequeue(), "first")

        queue.enqueue("second")
        queue.enqueue("third")
        XCTAssertEqual(queue.dequeue(), "second")
        XCTAssertEqual(queue.dequeue(), "third")
        XCTAssertNil(queue.dequeue())
    }
}

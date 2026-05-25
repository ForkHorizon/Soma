import XCTest
@testable import Moodling

final class CooldownPolicyTests: XCTestCase {
    func testQuietHoursCrossMidnight() {
        let policy = CooldownPolicy()
        XCTAssertTrue(policy.isQuietTime(currentMinute: 30, start: 23 * 60, end: 8 * 60))
        XCTAssertFalse(policy.isQuietTime(currentMinute: 22 * 60, start: 23 * 60, end: 8 * 60))
    }
}

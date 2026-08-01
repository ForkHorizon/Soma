import XCTest
@testable import Soma

final class RecordingRetentionTests: XCTestCase {
    /// "Never" is spelled 0 days, and 0 days must mean *no cutoff* — not a cutoff
    /// of "now", which is what the arithmetic alone produces and which would wipe
    /// the entire library the moment someone picked it.
    func testZeroDaysMeansKeepForever() {
        XCTAssertNil(ASRManager.retentionCutoff(days: 0, now: Date()))
    }

    func testCutoffIsExactlyThatManyDaysBack() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(ASRManager.retentionCutoff(days: 90, now: now), now.addingTimeInterval(-90 * 24 * 60 * 60))
        XCTAssertEqual(ASRManager.retentionCutoff(days: 14, now: now), now.addingTimeInterval(-14 * 24 * 60 * 60))
    }

    func testDefaultIsThreeMonths() {
        XCTAssertEqual(ASRManager.defaultRetentionDays, 90)
    }
}

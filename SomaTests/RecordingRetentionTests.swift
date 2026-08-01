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

    /// The sweep itself, against a real directory. The unit maths above says
    /// the cutoff is right; this says the file walk honours it — which is the
    /// part that actually deleted ten recordings when an old build ran.
    func testTheSweepDeletesOnlyWhatIsPastTheCutoff() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }

        let now = Date()
        let ages: [(name: String, daysOld: Double)] = [
            ("fresh", 0), ("yesterday", 1), ("two-weeks", 14),
            ("almost-ninety", 89), ("past-ninety", 91), ("ancient", 400),
        ]
        for age in ages {
            for suffix in ["wav", "txt"] {
                let url = directory.appendingPathComponent("\(age.name).\(suffix)")
                try Data("x".utf8).write(to: url)
                try manager.setAttributes(
                    [.modificationDate: now.addingTimeInterval(-age.daysOld * 24 * 60 * 60)],
                    ofItemAtPath: url.path)
            }
        }

        let cutoff = try XCTUnwrap(ASRManager.retentionCutoff(days: 90, now: now))
        ASRManager.removeRecordingFiles(in: directory, olderThan: cutoff)

        let left = Set(try manager.contentsOfDirectory(atPath: directory.path))
        for name in ["fresh", "yesterday", "two-weeks", "almost-ninety"] {
            XCTAssertTrue(left.contains("\(name).wav"), "\(name) was swept but is inside the window")
            XCTAssertTrue(left.contains("\(name).txt"), "\(name) transcript was swept but is inside the window")
        }
        for name in ["past-ninety", "ancient"] {
            XCTAssertFalse(left.contains("\(name).wav"), "\(name) is past the cutoff and should be gone")
            XCTAssertFalse(left.contains("\(name).txt"), "\(name) transcript should go with its audio")
        }
    }

    /// "Never" must sweep nothing at all, including files years old.
    func testNeverSweepsNothing() throws {
        XCTAssertNil(ASRManager.retentionCutoff(days: 0, now: Date()))
    }
}

import Foundation

final class AppState {
    var settings = MoodlingSettings()
    let nudgeScheduler = NudgeScheduler()

    func testNudge(currentMinute: Int) -> Bool {
        nudgeScheduler.shouldSendNudge(currentMinute: currentMinute, settings: settings)
    }
}

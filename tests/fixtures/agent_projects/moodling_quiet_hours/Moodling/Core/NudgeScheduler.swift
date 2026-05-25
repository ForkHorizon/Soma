import Foundation

struct NudgeScheduler {
    let cooldownPolicy = CooldownPolicy()

    func shouldSendNudge(currentMinute: Int, settings: MoodlingSettings) -> Bool {
        guard settings.quietHoursEnabled else { return true }
        return !cooldownPolicy.isQuietTime(
            currentMinute: currentMinute,
            start: settings.quietHoursStartMinutes,
            end: settings.quietHoursEndMinutes
        )
    }
}

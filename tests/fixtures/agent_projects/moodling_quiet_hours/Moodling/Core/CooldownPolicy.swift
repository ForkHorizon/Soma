import Foundation

struct CooldownPolicy {
    func isQuietTime(currentMinute: Int, start: Int, end: Int) -> Bool {
        if start == end { return true }
        if start < end {
            return currentMinute >= start && currentMinute < end
        }
        return currentMinute >= start || currentMinute < end
    }
}

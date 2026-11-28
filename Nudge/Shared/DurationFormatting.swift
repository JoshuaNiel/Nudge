import Foundation

// MARK: - Duration formatting
// Compiled into every target via the `Shared/` synchronized folder: used by the SMS
// copy in `NudgeMessages`, the Goals screen, and the dashboard report extension.
extension Int {
    /// Formats a duration in seconds as a human-readable string.
    /// e.g. 5400 → "1h 30m", 600 → "10m", 3660 → "1h 1m", 45 → "< 1m", 0 → "0m"
    var formattedDuration: String {
        let hours = self / 3600
        let minutes = (self % 3600) / 60
        if hours > 0 && minutes > 0 { return "\(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        if self > 0 { return "< 1m" }
        return "0m"
    }
}

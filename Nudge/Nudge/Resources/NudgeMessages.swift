import Foundation

/// Message templates for outbound SMS nudges.
/// The iOS extension uses these to compose the `report` string it POSTs to the
/// `send-nudge` Edge Function. The Edge Function appends the reply-options suffix
/// (defined in `supabase/functions/_shared/messages.ts`) before sending via Twilio.
///
/// Keep copy plain — no emojis (ADR-041).
/// To update wording, change the functions here only.
enum NudgeMessages {

    // MARK: - Goal breach

    static func goalBreachApp(userName: String, limitMinutes: Int, appName: String) -> String {
        "\(userName) just hit their \(limitMinutes)-minute limit on \(appName)."
    }

    static func goalBreachCategory(userName: String, limitMinutes: Int, categoryName: String) -> String {
        "\(userName) just hit their \(limitMinutes)-minute limit on \(categoryName)."
    }

    static func goalBreachTotal(userName: String, limitMinutes: Int) -> String {
        "\(userName) just hit their \(limitMinutes)-minute daily screen time limit."
    }

    // MARK: - Session timeout

    static func sessionTimeout(userName: String, minutes: Int) -> String {
        "\(userName) has been on their phone for \(minutes) minutes."
    }

    // MARK: - Daily report (sent at midnight intervalDidEnd)

    /// `totalSeconds` is the day's total. `topApps` is already sorted descending;
    /// only the first 3 are used (ADR-041).
    static func dailyReport(
        userName: String,
        totalSeconds: Int,
        topApps: [(name: String, seconds: Int)]
    ) -> String {
        let totalStr = totalSeconds.formattedDuration
        let appLines = topApps.prefix(3)
            .map { "\($0.name) (\($0.seconds.formattedDuration))" }
            .joined(separator: ", ")

        if appLines.isEmpty {
            return "\(userName)'s screen time yesterday: \(totalStr)."
        }
        return "\(userName)'s screen time yesterday: \(totalStr). Top apps: \(appLines)."
    }

    // MARK: - Convenience: compose from GoalSummary

    /// Returns the appropriate message for the goal that just fired.
    static func reportForGoal(userName: String, goalSummary: GoalSummary) -> String {
        let limitMinutes = goalSummary.limitSeconds / 60

        if goalSummary.eventName == "session.timeout" {
            return sessionTimeout(userName: userName, minutes: limitMinutes)
        }
        if goalSummary.eventName.hasPrefix("app.") {
            return goalBreachApp(userName: userName, limitMinutes: limitMinutes, appName: goalSummary.targetLabel)
        }
        if goalSummary.eventName.hasPrefix("category.") {
            return goalBreachCategory(userName: userName, limitMinutes: limitMinutes, categoryName: goalSummary.targetLabel)
        }
        // default: total
        return goalBreachTotal(userName: userName, limitMinutes: limitMinutes)
    }
}

// MARK: - Duration formatting
// Used by NudgeMessages and Phase 2 dashboard. When the extension target needs
// this, duplicate it there or extract to a shared framework.
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

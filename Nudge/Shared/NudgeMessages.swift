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

    // MARK: - Daily report (Phase 5E-2: total only, approximate)

    /// Yesterday's total, from the highest `total.m<NN>` milestone reached, so it is
    /// accurate to the 15-minute step — hence "about". Reaching the 12 h milestone reads
    /// "over 12 hours". Below the first milestone reads "under 15 minutes", although the
    /// enqueue path never sends a report with nothing recorded.
    static func dailyReport(userName: String, totalMinutes: Int) -> String {
        let amount: String
        if totalMinutes >= MonitoringPlan.dailyTotalMaxMinutes {
            amount = "over \(MonitoringPlan.dailyTotalMaxMinutes / 60) hours"
        } else if totalMinutes < MonitoringPlan.dailyTotalStepMinutes {
            amount = "under \(MonitoringPlan.dailyTotalStepMinutes) minutes"
        } else {
            amount = "about \((totalMinutes * 60).formattedDuration)"
        }
        return "\(userName)'s screen time yesterday: \(amount)."
    }

    // MARK: - Limit reached (local notification on the user's own device)

    static func limitReachedTitle(label: String) -> String {
        "You've hit your \(label) limit"
    }

    static func limitReachedBody(label: String, limitSeconds: Int) -> String {
        "You set a \(limitSeconds.formattedDuration) daily limit on \(label)."
    }

    // MARK: - Why-reminder (local notification at a why's percent, Phase 4)

    /// Title for a p10–p90 why-reminder. The body is the user's own why.
    static func milestoneReminderTitle(percent: Int, label: String) -> String {
        "You're at \(percent)% of your \(label) limit"
    }

    // MARK: - Convenience: compose from GoalSummary

    /// Returns the SMS report for the goal (or session timeout) that just fired.
    /// Switches on `targetType`: since Phase 3a event names are `goal.<id>.pNN` and no
    /// longer encode the target.
    static func reportForGoal(userName: String, goalSummary: GoalSummary) -> String {
        let limitMinutes = goalSummary.limitSeconds / 60

        if goalSummary.isSessionTimeout {
            return sessionTimeout(userName: userName, minutes: limitMinutes)
        }
        switch goalSummary.targetType {
        case .app:
            return goalBreachApp(userName: userName, limitMinutes: limitMinutes, appName: goalSummary.targetLabel)
        case .category:
            return goalBreachCategory(userName: userName, limitMinutes: limitMinutes, categoryName: goalSummary.targetLabel)
        case .total:
            return goalBreachTotal(userName: userName, limitMinutes: limitMinutes)
        }
    }
}

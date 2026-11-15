import Foundation

/// Title + body of a local notification about the user's own goal.
struct GoalNotificationContent: Equatable {
    let title: String
    let body: String
}

/// Composes the monitor extension's goal notifications (Phase 4). Pure, so the copy for
/// every case is unit-tested; the extension only posts the result.
enum GoalNotificationComposer {

    /// p10–p90: a notification only when the user has a why at this percent.
    static func milestone(goal: GoalSummary, percent: Int, why: String?) -> GoalNotificationContent? {
        guard let why else { return nil }
        return GoalNotificationContent(
            title: NudgeMessages.milestoneReminderTitle(percent: percent, label: goal.targetLabel),
            body: why
        )
    }

    /// p100 always notifies. A why at 100 replaces the generic body — one notification,
    /// not two.
    static func limitReached(goal: GoalSummary, why: String?) -> GoalNotificationContent {
        GoalNotificationContent(
            title: NudgeMessages.limitReachedTitle(label: goal.targetLabel),
            body: why ?? NudgeMessages.limitReachedBody(label: goal.targetLabel, limitSeconds: goal.limitSeconds)
        )
    }
}

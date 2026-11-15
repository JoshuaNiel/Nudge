import Foundation

/// What the monitor extension should do for a threshold callback, after the progress
/// and dedup bookkeeping has been applied.
enum ThresholdOutcome: Equatable {
    /// p10–p90: progress recorded; the extension shows a why-reminder if one exists (Phase 4).
    case milestone(goal: GoalSummary, percent: Int)
    /// p100: the goal's limit was reached.
    case goalReached(goal: GoalSummary)
    /// The session-timeout pseudo-goal fired.
    case sessionTimeout(GoalSummary)
    /// A `total.m<NN>` milestone: recorded for the daily report; no other side effect.
    case dailyTotal(minutes: Int)
    /// Already handled today; skip every side effect.
    case duplicate(eventName: String)
    /// The name is unknown, or names a goal missing from the catalog — monitoring and the
    /// App Group disagree.
    case unmatched(eventName: String)
}

/// The decision half of `NudgeMonitor.eventDidReachThreshold`, kept in `Shared/` so it is
/// unit-tested and the extension only performs side effects.
enum ThresholdRouter {

    /// Parses `eventName`, matches it against `catalog`, and applies the once-per-day
    /// dedup (`store.markFired`) and progress merge for `day`. Unmatched events are not
    /// marked, so a later, correct registration can still fire them.
    static func route(
        eventName: String,
        catalog: [GoalSummary],
        store: GoalProgressStore,
        day: String
    ) -> ThresholdOutcome {
        switch MonitoringPlan.parseEventName(eventName) {
        case let .milestone(goalId, percent):
            guard let goal = catalog.first(where: { !$0.isSessionTimeout && $0.goalId == goalId }) else {
                return .unmatched(eventName: eventName)
            }
            guard store.markFired(eventName, onDay: day) else { return .duplicate(eventName: eventName) }
            store.recordProgress(goalId: goalId, percent: percent, day: day)
            return percent >= 100 ? .goalReached(goal: goal) : .milestone(goal: goal, percent: percent)

        case .sessionTimeout:
            guard let session = catalog.first(where: \.isSessionTimeout) else {
                return .unmatched(eventName: eventName)
            }
            guard store.markFired(eventName, onDay: day) else { return .duplicate(eventName: eventName) }
            return .sessionTimeout(session)

        case let .dailyTotal(minutes):
            // Needs no catalog entry. Max-merge is idempotent, so the fired set is not
            // consulted: there is no side effect to dedup.
            store.recordDailyTotal(minutes: minutes, day: day)
            return .dailyTotal(minutes: minutes)

        case .unknown:
            return .unmatched(eventName: eventName)
        }
    }
}

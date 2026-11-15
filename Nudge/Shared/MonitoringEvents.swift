import Foundation

/// What a `DeviceActivityEvent.Name` refers to, decoded from its raw value.
enum MonitoredEvent: Equatable {
    /// `goal.<id>.p<NN>` — the goal reached NN% of its limit.
    case milestone(goalId: Int, percent: Int)
    /// `session.timeout` — the session-timeout pseudo-goal fired.
    case sessionTimeout
    /// `total.m<NN>` — total device usage today reached NN minutes (Phase 5E daily report).
    case dailyTotal(minutes: Int)
    /// Anything else, including pre-3a names (`total`, `app.<bundle>`, `category.<id>`).
    case unknown
}

// MARK: - Event naming (Phase 3 G3, supersedes ADR-036 for goals)
//
// Names are `goal.<id>.p<NN>` with NN ∈ {10, 20, …, 100}, written without zero padding
// (`goal.42.p10`, `goal.42.p100`). `session.timeout` is unchanged. Parsing accepts only
// the canonical spelling a registration could have produced, so a name is either one we
// registered or `.unknown` — never a near miss.
//
// Daily report (Phase 5E-2): `total.m<NN>` with NN ∈ {15, 30, …, 720} minutes, no zero
// padding (`total.m15`, `total.m720`), all device usage (no app filter). Registered only
// while the daily report is on. Distinct from the pre-3a legacy name `total`, which is
// still `.unknown`.

extension MonitoringPlan {

    static let sessionTimeoutEventName = "session.timeout"

    /// Milestones are registered every `milestoneStepPercent` percent of a goal's limit.
    /// Must divide 100.
    static let milestoneStepPercent = 10

    static var milestonePercents: [Int] {
        Array(stride(from: milestoneStepPercent, through: 100, by: milestoneStepPercent))
    }

    private static let goalEventPrefix = "goal."
    private static let percentMarker = "p"

    /// `goal.<id>` — the prefix shared by a goal's milestone events; also the goal's
    /// `GoalSummary.eventName`.
    static func goalEventBase(goalId: Int) -> String {
        "\(goalEventPrefix)\(goalId)"
    }

    static func milestoneEventName(goalId: Int, percent: Int) -> String {
        "\(goalEventBase(goalId: goalId)).\(percentMarker)\(percent)"
    }

    /// `limitSeconds * percent / 100`, floored (so a milestone never fires *after* its
    /// percentage) and at least 1 s. p100 is always exactly `limitSeconds`.
    static func milestoneThresholdSeconds(limitSeconds: Int, percent: Int) -> Int {
        max(1, limitSeconds * percent / 100)
    }

    // MARK: Daily total milestones (Phase 5E-2)

    /// Total-usage milestones are registered every `dailyTotalStepMinutes` minutes up to
    /// `dailyTotalMaxMinutes`. The report is only as precise as the step.
    static let dailyTotalStepMinutes = 15
    static let dailyTotalMaxMinutes = 720

    static var dailyTotalMilestoneMinutes: [Int] {
        Array(stride(from: dailyTotalStepMinutes, through: dailyTotalMaxMinutes, by: dailyTotalStepMinutes))
    }

    private static let dailyTotalEventPrefix = "total.m"

    static func dailyTotalEventName(minutes: Int) -> String {
        "\(dailyTotalEventPrefix)\(minutes)"
    }

    /// The 48 total-usage events (no app filter); threshold = the milestone in seconds.
    static var dailyTotalEventSpecs: [EventSpec] {
        dailyTotalMilestoneMinutes.map {
            EventSpec(name: dailyTotalEventName(minutes: $0), thresholdSeconds: $0 * 60)
        }
    }

    static func parseEventName(_ name: String) -> MonitoredEvent {
        if name == sessionTimeoutEventName { return .sessionTimeout }
        if name.hasPrefix(dailyTotalEventPrefix) { return parseDailyTotal(name) }
        guard name.hasPrefix(goalEventPrefix) else { return .unknown }

        let parts = name.dropFirst(goalEventPrefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[1].hasPrefix(percentMarker),
              let goalId = Int(parts[0]), goalId > 0,
              let percent = Int(parts[1].dropFirst(percentMarker.count)),
              milestonePercents.contains(percent),
              // Reject non-canonical spellings Int() tolerates ("+42", "010").
              milestoneEventName(goalId: goalId, percent: percent) == name
        else { return .unknown }

        return .milestone(goalId: goalId, percent: percent)
    }

    private static func parseDailyTotal(_ name: String) -> MonitoredEvent {
        guard let minutes = Int(name.dropFirst(dailyTotalEventPrefix.count)),
              dailyTotalMilestoneMinutes.contains(minutes),
              // Reject non-canonical spellings Int() tolerates ("+15", "015").
              dailyTotalEventName(minutes: minutes) == name
        else { return .unknown }
        return .dailyTotal(minutes: minutes)
    }

    // MARK: - Event specs (pure)

    /// Name + threshold for one event, independent of `DeviceActivity` types so the
    /// naming and threshold rules can be unit-tested without tokens.
    struct EventSpec: Equatable {
        let name: String
        let thresholdSeconds: Int
    }

    /// The events a summary contributes: one `session.timeout` event for the session
    /// pseudo-goal, otherwise one milestone per `milestonePercents` step.
    static func eventSpecs(for summary: GoalSummary) -> [EventSpec] {
        if summary.isSessionTimeout {
            return [EventSpec(name: sessionTimeoutEventName, thresholdSeconds: summary.limitSeconds)]
        }
        return milestonePercents.map { percent in
            EventSpec(
                name: milestoneEventName(goalId: summary.goalId, percent: percent),
                thresholdSeconds: milestoneThresholdSeconds(limitSeconds: summary.limitSeconds, percent: percent)
            )
        }
    }
}

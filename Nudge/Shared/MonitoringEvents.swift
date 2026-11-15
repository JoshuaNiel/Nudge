import Foundation

/// What a `DeviceActivityEvent.Name` refers to, decoded from its raw value.
enum MonitoredEvent: Equatable {
    /// `goal.<id>.p<NN>` — the goal reached NN% of its limit.
    case milestone(goalId: Int, percent: Int)
    /// `session.timeout` — the session-timeout pseudo-goal fired.
    case sessionTimeout
    /// Anything else, including pre-3a names (`total`, `app.<bundle>`, `category.<id>`).
    case unknown
}

// MARK: - Event naming (Phase 3 G3, supersedes ADR-036 for goals)
//
// Names are `goal.<id>.p<NN>` with NN ∈ {10, 20, …, 100}, written without zero padding
// (`goal.42.p10`, `goal.42.p100`). `session.timeout` is unchanged. Parsing accepts only
// the canonical spelling a registration could have produced, so a name is either one we
// registered or `.unknown` — never a near miss.

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

    static func parseEventName(_ name: String) -> MonitoredEvent {
        if name == sessionTimeoutEventName { return .sessionTimeout }
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

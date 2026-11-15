import Foundation

// MARK: - App Group data structures
// These types are serialized to/from the shared App Group container to pass data
// between the main app and the DeviceActivityMonitor extension.

/// A fired trigger written by the DeviceActivityMonitor extension (Strategy 2 fallback).
/// Read by NudgeTriggerService when the main app wakes via BGProcessingTask.
struct PendingTrigger: Codable {
    let eventName: String   // e.g. "goal.42.p100", "session.timeout"
    let report: String      // pre-built SMS report text (composed by the extension)
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case eventName = "event_name"
        case report
        case timestamp
    }
}

/// One entry of the monitored catalog, written to the App Group by `MonitoringPlan.register`
/// and read by the DeviceActivityMonitor extension (re-arm at midnight, milestone
/// handling, nudge copy).
///
/// - Goals: `eventName` is the milestone prefix `goal.<id>`; the registered events are
///   `goal.<id>.p10` … `goal.<id>.p100` (see `MonitoringPlan.eventSpecs`).
/// - Session timeout pseudo-goal: `eventName == "session.timeout"`, `goalId == 0`,
///   `targetType == .total` (it measures all device usage).
///
/// **Backward compatible:** every field added in Phase 3a is decoded with
/// `decodeIfPresent` and a default, so App Group JSON written by the previous version
/// still decodes after an upgrade — the extension may re-arm from it before the app is
/// ever reopened.
struct GoalSummary: Codable, Equatable {
    let goalId: Int
    let eventName: String
    let limitSeconds: Int
    let targetLabel: String         // e.g. "Instagram", "Social Media", "All Apps"
    let targetType: GoalTargetType
    let frequency: GoalFrequency
    let startDate: String?          // "yyyy-MM-dd", temporary goals only (inclusive)
    let endDate: String?            // "yyyy-MM-dd", temporary goals only (inclusive)
    /// PropertyList bytes of the `FamilyActivitySelection` (app goal: its own; category
    /// goal: the category's). `nil` for total goals and session timeout.
    let selectionData: Data?

    init(
        goalId: Int,
        eventName: String,
        limitSeconds: Int,
        targetLabel: String,
        targetType: GoalTargetType,
        frequency: GoalFrequency = .daily,
        startDate: String? = nil,
        endDate: String? = nil,
        selectionData: Data? = nil
    ) {
        self.goalId = goalId
        self.eventName = eventName
        self.limitSeconds = limitSeconds
        self.targetLabel = targetLabel
        self.targetType = targetType
        self.frequency = frequency
        self.startDate = startDate
        self.endDate = endDate
        self.selectionData = selectionData
    }

    var isSessionTimeout: Bool { eventName == MonitoringPlan.sessionTimeoutEventName }

    enum CodingKeys: String, CodingKey {
        case goalId        = "goal_id"
        case eventName     = "event_name"
        case limitSeconds  = "limit_seconds"
        case targetLabel   = "target_label"
        case targetType    = "target_type"
        case frequency
        case startDate     = "start_date"
        case endDate       = "end_date"
        case selectionData = "selection_data"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goalId = try c.decode(Int.self, forKey: .goalId)
        eventName = try c.decode(String.self, forKey: .eventName)
        limitSeconds = try c.decode(Int.self, forKey: .limitSeconds)
        targetLabel = try c.decode(String.self, forKey: .targetLabel)
        targetType = try c.decodeIfPresent(GoalTargetType.self, forKey: .targetType)
            ?? Self.legacyTargetType(forEventName: eventName)
        frequency = try c.decodeIfPresent(GoalFrequency.self, forKey: .frequency) ?? .daily
        startDate = try c.decodeIfPresent(String.self, forKey: .startDate)
        endDate = try c.decodeIfPresent(String.self, forKey: .endDate)
        selectionData = try c.decodeIfPresent(Data.self, forKey: .selectionData)
    }

    /// Pre-3a summaries encoded the target in the event name (ADR-036:
    /// `app.<bundle>`, `category.<id>`, `total`, `session.timeout`).
    private static func legacyTargetType(forEventName name: String) -> GoalTargetType {
        if name.hasPrefix("app.") { return .app }
        if name.hasPrefix("category.") { return .category }
        return .total
    }
}

/// Minimal friend info written to App Group by AppState after loading friends.
/// Read by the DeviceActivityMonitor extension to know which friend IDs to notify.
struct FriendSummary: Codable {
    let id: Int

    enum CodingKeys: String, CodingKey {
        case id
    }
}

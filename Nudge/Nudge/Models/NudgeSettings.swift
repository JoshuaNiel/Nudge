import Foundation

// MARK: - NudgeSettings

/// The user's nudge trigger settings — one `public.nudge_settings` row (migration 008,
/// Phase 5E). No row means `defaults`; the app upserts a row on first save.
struct NudgeSettings: Codable, Equatable {
    var sessionTimeoutEnabled: Bool
    /// One of `allowedSessionTimeoutMinutes` (enforced by a DB CHECK).
    var sessionTimeoutMinutes: Int
    var goalBreachEnabled: Bool
    /// Stored and shown in 5E-1; sending arrives in 5E-2.
    var dailyReportEnabled: Bool
    var dailyReportTime: TimeOfDay

    enum CodingKeys: String, CodingKey {
        case sessionTimeoutEnabled = "session_timeout_enabled"
        case sessionTimeoutMinutes = "session_timeout_minutes"
        case goalBreachEnabled     = "goal_breach_enabled"
        case dailyReportEnabled    = "daily_report_enabled"
        case dailyReportTime       = "daily_report_time"
    }

    /// Must match the `nudge_settings_session_timeout_minutes_allowed` CHECK.
    static let allowedSessionTimeoutMinutes = [15, 30, 60, 90, 120]

    /// Must match the column defaults in `008_nudge_settings.sql`.
    static let defaults = NudgeSettings(
        sessionTimeoutEnabled: true,
        sessionTimeoutMinutes: 60,
        goalBreachEnabled: false,
        dailyReportEnabled: false,
        dailyReportTime: TimeOfDay(hour: 8, minute: 0)
    )

    /// The value monitoring is registered with: `nil` = no `session.timeout` event.
    var effectiveSessionTimeoutMinutes: Int? {
        sessionTimeoutEnabled ? sessionTimeoutMinutes : nil
    }

    /// The App Group mirror the monitor extension reads.
    var triggerSettings: NudgeTriggerSettings {
        NudgeTriggerSettings(
            goalBreachEnabled: goalBreachEnabled,
            dailyReportEnabled: dailyReportEnabled,
            dailyReportTime: dailyReportTime
        )
    }

    /// A fetch returns zero or one row (`user_id` is the primary key). Zero → defaults.
    static func resolve(rows: [NudgeSettings]) -> NudgeSettings {
        rows.first ?? defaults
    }
}

// MARK: - Upsert payload

/// Body of the `nudge_settings` upsert. `updated_at` is omitted on purpose: a DB trigger
/// sets it, so it never depends on the device clock.
struct NudgeSettingsUpsert: Encodable {
    let userId: UUID
    let settings: NudgeSettings

    private enum CodingKeys: String, CodingKey {
        case userId = "user_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userId, forKey: .userId)
        // Same keyed container, so the settings columns sit beside user_id.
        try settings.encode(to: encoder)
    }
}

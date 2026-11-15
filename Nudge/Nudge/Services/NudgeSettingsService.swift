import Foundation
import Supabase

// MARK: - Protocol

protocol NudgeSettingsServiceProtocol {
    /// The user's settings, or `NudgeSettings.defaults` when they have no row yet.
    /// Throws on any request failure — never returns defaults in place of an error
    /// (ADR-055: monitoring must not be rebuilt from data that failed to load).
    func fetch(userId: UUID) async throws -> NudgeSettings

    /// Creates or replaces the user's row (upsert on `user_id`).
    func save(_ settings: NudgeSettings, userId: UUID) async throws
}

// MARK: - Service

@MainActor
final class NudgeSettingsService: NudgeSettingsServiceProtocol {

    private static let table = "nudge_settings"
    private static let columns =
        "session_timeout_enabled, session_timeout_minutes, goal_breach_enabled, daily_report_enabled, daily_report_time"

    func fetch(userId: UUID) async throws -> NudgeSettings {
        // An array rather than `.single()`: zero rows is a valid answer (defaults), and
        // `.single()` would turn it into an error indistinguishable from a real failure.
        let rows: [NudgeSettings] = try await supabase
            .from(Self.table)
            .select(Self.columns)
            .eq("user_id", value: userId)
            .limit(1)
            .execute()
            .value
        return NudgeSettings.resolve(rows: rows)
    }

    func save(_ settings: NudgeSettings, userId: UUID) async throws {
        try await supabase
            .from(Self.table)
            .upsert(NudgeSettingsUpsert(userId: userId, settings: settings), onConflict: "user_id", returning: .minimal)
            .execute()
    }
}

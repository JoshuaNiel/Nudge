import Foundation
import os

// Compiled into the app and both extensions via the `Shared/` synchronized folder
// (ADR-056), so the app's writer and the monitor extension's reader cannot drift.

// MARK: - TimeOfDay

/// A wall-clock time with minute precision, as stored in a Postgres `time` column
/// (`nudge_settings.daily_report_time`).
///
/// Codable as a single string. Decoding accepts `"HH:mm"`, `"HH:mm:ss"` and
/// `"HH:mm:ss.ffffff"` (Postgres returns the seconds form; seconds are dropped because the
/// picker is minute-precision). Encoding always writes `"HH:mm:ss"`, which Postgres
/// accepts and returns unchanged, so a round trip through the DB is the identity.
struct TimeOfDay: Codable, Equatable, Hashable {
    let hour: Int
    let minute: Int

    init(hour: Int, minute: Int) {
        precondition((0...23).contains(hour) && (0...59).contains(minute), "invalid TimeOfDay \(hour):\(minute)")
        self.hour = hour
        self.minute = minute
    }

    /// Parses `"HH:mm"`, `"HH:mm:ss"` or `"HH:mm:ss.ffffff"`. Returns nil for anything
    /// else, including out-of-range components.
    init?(string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let hour = Self.component(parts[0], range: 0...23),
              let minute = Self.component(parts[1], range: 0...59) else { return nil }
        if parts.count == 3 {
            // Seconds, optionally with a fractional part. Validated, then discarded.
            let seconds = parts[2].split(separator: ".", omittingEmptySubsequences: false)
            guard seconds.count <= 2,
                  Self.component(seconds[0], range: 0...59) != nil,
                  seconds.count == 1 || (!seconds[1].isEmpty && seconds[1].allSatisfy(\.isASCIIDigit)) else {
                return nil
            }
        }
        self.hour = hour
        self.minute = minute
    }

    /// The local time of day of `date` in `calendar`.
    init(date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    /// `"HH:mm:ss"`, zero-padded — the Postgres `time` text format.
    var postgresString: String { String(format: "%02d:%02d:00", hour, minute) }

    /// This time on the local calendar day containing `day`. On a DST transition day
    /// where the wall-clock time does not exist, `Calendar` resolves to the next valid
    /// time; falls back to the start of the day if no date can be formed.
    func date(on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
            ?? calendar.startOfDay(for: day)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = TimeOfDay(string: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "expected HH:mm or HH:mm:ss, got \(raw)"
            )
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(postgresString)
    }

    /// Exactly two ASCII digits within `range`.
    private static func component(_ text: Substring, range: ClosedRange<Int>) -> Int? {
        guard text.count == 2, text.allSatisfy(\.isASCIIDigit), let value = Int(text),
              range.contains(value) else { return nil }
        return value
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

// MARK: - NudgeTriggerSettings

/// The part of the user's nudge settings the monitor extension needs with the app closed,
/// mirrored to the App Group under `AppGroupKeys.nudgeSettings` (Phase 5E).
///
/// The session timeout is deliberately not here: it is already part of the monitored
/// catalog (`MonitoringPlan.catalog`), and so part of the registration signature.
///
/// Written by the app on every successful settings load and save. Never written from
/// data that failed to load (ADR-055).
struct NudgeTriggerSettings: Codable, Equatable {
    let goalBreachEnabled: Bool
    let dailyReportEnabled: Bool
    let dailyReportTime: TimeOfDay

    enum CodingKeys: String, CodingKey {
        case goalBreachEnabled  = "goal_breach_enabled"
        case dailyReportEnabled = "daily_report_enabled"
        case dailyReportTime    = "daily_report_time"
    }

    /// What the extension assumes when nothing readable is stored (fresh install, signed
    /// out, or corrupt data): every friend-facing trigger off. It matches the DB defaults
    /// for these columns, and it fails closed on purpose — the wrong default here would
    /// text the user's friends without their say-so, which is worse than a missed nudge.
    static let failClosed = NudgeTriggerSettings(
        goalBreachEnabled: false,
        dailyReportEnabled: false,
        dailyReportTime: TimeOfDay(hour: 8, minute: 0)
    )

    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "NudgeTriggerSettings")

    /// Reads the mirrored settings. Missing or undecodable → `failClosed`.
    static func load(from defaults: UserDefaults?) -> NudgeTriggerSettings {
        guard let data = defaults?.data(forKey: AppGroupKeys.nudgeSettings) else { return failClosed }
        guard let settings = try? JSONDecoder().decode(NudgeTriggerSettings.self, from: data) else {
            logger.error("nudge settings in App Group failed to decode — failing closed")
            return failClosed
        }
        return settings
    }

    static func persist(_ settings: NudgeTriggerSettings, defaults: UserDefaults?) {
        guard let defaults else { return }
        guard let data = try? JSONEncoder().encode(settings) else {
            logger.error("failed to encode nudge settings")
            return
        }
        defaults.set(data, forKey: AppGroupKeys.nudgeSettings)
    }
}

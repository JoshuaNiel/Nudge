import Foundation

// MARK: - Dashboard usage model (Phase 2)
//
// Pure value types and functions behind the dashboard. The `NudgeActivityReport`
// extension maps Apple's `DeviceActivityData` into the plain `*Sample` inputs below
// and calls `DailyUsageSummary.aggregate`. Keeping the logic here — free of
// `DeviceActivity` types, which have no public initializers — is what makes it unit
// testable; the extension itself is a thin adapter.
//
// `Token` is generic so the extension can carry `ApplicationToken` through to the
// view (to render the real app name + icon with `Label(token)`) while tests use any
// `Hashable` stand-in.

/// One app's activity as reported in one segment, before merging.
struct AppUsageSample<Token: Hashable> {
    let bundleId: String?
    let localizedName: String?
    let token: Token?
    let duration: TimeInterval
    let pickups: Int
}

/// One `ActivitySegment` worth of activity.
struct UsageSegmentSample<Token: Hashable> {
    /// The segment's total activity — includes time not attributed to a listed app.
    let totalDuration: TimeInterval
    /// Pickups where the user did not go on to open an app.
    let pickupsWithoutApp: Int
    let apps: [AppUsageSample<Token>]
}

/// Merge key for an app. Bundle id is the stable identity; a token or a name is
/// used only when the system withholds the bundle id.
enum AppUsageKey<Token: Hashable>: Hashable {
    case bundle(String)
    case token(Token)
    case name(String)
}

/// One row on the dashboard: a single app's usage for the day.
struct AppUsageEntry<Token: Hashable>: Identifiable {
    let id: AppUsageKey<Token>
    let bundleId: String?
    let displayName: String
    let token: Token?
    let seconds: Int
    let pickups: Int
}

/// A single day's usage, ready to render.
struct DailyUsageSummary<Token: Hashable> {
    let totalSeconds: Int
    let totalPickups: Int
    /// Sorted by seconds descending, then display name.
    let apps: [AppUsageEntry<Token>]

    /// No screen time recorded — the view shows its empty state.
    var isEmpty: Bool { totalSeconds == 0 }

    static var empty: DailyUsageSummary<Token> {
        DailyUsageSummary(totalSeconds: 0, totalPickups: 0, apps: [])
    }

    /// Merges per-app samples across all segments into one summary.
    ///
    /// - Apps are merged by `AppUsageKey`; seconds and pickups are summed. Samples
    ///   with no bundle id, token or name cannot be identified and are dropped from
    ///   the list (their time still counts toward the segment totals).
    /// - Apps with neither time nor pickups are omitted.
    /// - `totalSeconds` is the sum of segment totals, but never less than the sum of
    ///   the listed apps, so a bar can never exceed its track.
    /// - Durations are summed as `TimeInterval` and rounded once at the end so
    ///   fractional seconds do not truncate away per segment.
    static func aggregate(_ segments: [UsageSegmentSample<Token>]) -> DailyUsageSummary<Token> {
        var byKey: [AppUsageKey<Token>: Accumulator] = [:]
        var segmentDuration: TimeInterval = 0
        var pickups = 0

        for segment in segments {
            segmentDuration += max(0, segment.totalDuration)
            pickups += max(0, segment.pickupsWithoutApp)

            for sample in segment.apps {
                pickups += max(0, sample.pickups)
                guard let key = key(for: sample) else { continue }

                var acc = byKey[key] ?? Accumulator()
                acc.bundleId = acc.bundleId ?? nonBlank(sample.bundleId)
                acc.localizedName = acc.localizedName ?? nonBlank(sample.localizedName)
                acc.token = acc.token ?? sample.token
                acc.duration += max(0, sample.duration)
                acc.pickups += max(0, sample.pickups)
                byKey[key] = acc
            }
        }

        let apps = byKey
            .map { key, acc in
                AppUsageEntry(
                    id: key,
                    bundleId: acc.bundleId,
                    displayName: AppUsageNaming.displayName(localizedName: acc.localizedName, bundleId: acc.bundleId),
                    token: acc.token,
                    seconds: Int(acc.duration.rounded()),
                    pickups: acc.pickups
                )
            }
            .filter { $0.seconds > 0 || $0.pickups > 0 }
            .sorted { isOrderedBefore($0, $1) }

        let appSeconds = apps.reduce(0) { $0 + $1.seconds }
        return DailyUsageSummary(
            totalSeconds: max(Int(segmentDuration.rounded()), appSeconds),
            totalPickups: pickups,
            apps: apps
        )
    }

    // MARK: - Private

    /// Running totals for one app while merging.
    private struct Accumulator {
        var bundleId: String?
        var localizedName: String?
        var token: Token?
        var duration: TimeInterval = 0
        var pickups = 0
    }

    private static func key(for sample: AppUsageSample<Token>) -> AppUsageKey<Token>? {
        if let bundleId = nonBlank(sample.bundleId) { return .bundle(bundleId) }
        if let token = sample.token { return .token(token) }
        if let name = nonBlank(sample.localizedName) { return .name(name) }
        return nil
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Seconds descending, then display name (case-insensitive), then a stable
    /// fallback so the order is deterministic across renders.
    private static func isOrderedBefore(_ a: AppUsageEntry<Token>, _ b: AppUsageEntry<Token>) -> Bool {
        if a.seconds != b.seconds { return a.seconds > b.seconds }
        let byName = a.displayName.caseInsensitiveCompare(b.displayName)
        if byName != .orderedSame { return byName == .orderedAscending }
        return (a.bundleId ?? "") < (b.bundleId ?? "")
    }
}

// MARK: - Display name

enum AppUsageNaming {

    static let unknownAppName = "Unknown App"

    /// The system's localized name when available; otherwise the last bundle id
    /// component with its first letter capitalized (`"com.google.ios.youtube"` →
    /// `"Youtube"`); otherwise the bundle id itself; otherwise "Unknown App".
    static func displayName(localizedName: String?, bundleId: String?) -> String {
        if let name = localizedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        guard let bundleId = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleId.isEmpty else {
            return unknownAppName
        }
        guard let last = bundleId.split(separator: ".", omittingEmptySubsequences: false).last,
              !last.isEmpty else {
            return bundleId
        }
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}

// MARK: - Bar geometry

enum UsageBar {

    /// Smallest visible bar for any app with non-zero usage.
    static let minimumWidth: Double = 2

    /// The share of the day's total, in `0...1`. Zero when either side is zero.
    static func fraction(seconds: Int, totalSeconds: Int) -> Double {
        guard totalSeconds > 0, seconds > 0 else { return 0 }
        return min(1, Double(seconds) / Double(totalSeconds))
    }

    /// Bar width for `fraction` of `availableWidth`, never thinner than
    /// `minimumWidth` (unless the fraction is zero) and never wider than the track.
    static func width(fraction: Double, availableWidth: Double) -> Double {
        guard fraction > 0, availableWidth > 0 else { return 0 }
        return min(availableWidth, max(minimumWidth, fraction * availableWidth))
    }
}

// MARK: - Copy

enum UsageFormatting {
    static func pickups(_ count: Int) -> String {
        count == 1 ? "1 pickup" : "\(count) pickups"
    }
}

// MARK: - Day navigation

/// Date math for the dashboard's day picker. All functions take the calendar
/// explicitly so the local-day boundaries are testable in a fixed time zone.
enum DashboardDay {

    /// How many days before today the user can navigate back to.
    static let maxDaysBack = 30

    /// The full local day containing `date` — the `DeviceActivityFilter` segment.
    /// Never zero-length (ADR-045).
    static func filterInterval(for date: Date, calendar: Calendar) -> DateInterval {
        if let interval = calendar.dateInterval(of: .day, for: date), interval.duration > 0 {
            return interval
        }
        return DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
    }

    static func isToday(_ day: Date, today: Date, calendar: Calendar) -> Bool {
        calendar.isDate(day, inSameDayAs: today)
    }

    /// Start of the oldest selectable day.
    static func earliestDay(today: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: today)
        return calendar.date(byAdding: .day, value: -maxDaysBack, to: start) ?? start
    }

    /// Normalizes `day` to its start of day and clamps it into
    /// `earliestDay ... startOfDay(today)`.
    static func clamp(_ day: Date, today: Date, calendar: Calendar) -> Date {
        let latest = calendar.startOfDay(for: today)
        let earliest = earliestDay(today: today, calendar: calendar)
        let normalized = calendar.startOfDay(for: day)
        return min(max(normalized, earliest), latest)
    }

    /// Moves `days` calendar days from `day`, clamped to the selectable range.
    static func step(_ day: Date, by days: Int, today: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        let moved = calendar.date(byAdding: .day, value: days, to: start) ?? start
        return clamp(moved, today: today, calendar: calendar)
    }

    static func canStepBack(from day: Date, today: Date, calendar: Calendar) -> Bool {
        calendar.startOfDay(for: day) > earliestDay(today: today, calendar: calendar)
    }

    static func canStepForward(from day: Date, today: Date, calendar: Calendar) -> Bool {
        calendar.startOfDay(for: day) < calendar.startOfDay(for: today)
    }

    /// "Today", "Yesterday", or a short month-day date such as "Apr 14".
    static func title(for day: Date, today: Date, calendar: Calendar, locale: Locale) -> String {
        if isToday(day, today: today, calendar: calendar) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: day)
    }
}

import Foundation

// Phase 3 G8 — exact usage for one goal, rendered by the report extension's `goalUsage`
// scene on the Goal detail screen. Pure values so the rules are unit-tested; the
// extension only walks `DeviceActivityResults` and hands the segment durations here.
// Compiled into every target via `Shared/` (Foundation only).

/// Today's usage for the apps/categories in a goal's `DeviceActivityFilter`.
struct GoalUsageSummary: Equatable {
    let totalSeconds: Int

    /// Sums the filtered segments' `totalActivityDuration`, rounding once at the end so
    /// many small segments don't drift. Never negative.
    static func total(ofSegmentDurations durations: [TimeInterval]) -> GoalUsageSummary {
        let sum = durations.reduce(0, +)
        return GoalUsageSummary(totalSeconds: max(0, Int(sum.rounded())))
    }

    /// "47m used today", or "No usage yet today" when nothing has been recorded.
    var text: String {
        totalSeconds > 0 ? "\(totalSeconds.formattedDuration) used today" : "No usage yet today"
    }
}

enum GoalUsageDay {
    /// The whole local day containing `now` — goals are daily (G6), and a zero-length
    /// filter returns no data (ADR-045). Same rule as the dashboard's day filter.
    static func filterInterval(now: Date, calendar: Calendar) -> DateInterval {
        DashboardDay.filterInterval(for: now, calendar: calendar)
    }
}

import Foundation

// MARK: - Dashboard report model (Phase 2 v2)
//
// What the `NudgeActivityReport` extension renders: the period's app totals (see
// `DailyUsageSummary` in UsageSummary.swift), Apple's Screen Time categories, and whether the
// report covers a day or a week — plus the pure math behind Totals | Averages (V4) and
// Apps | Categories (V5). Free of `DeviceActivity` types so it is unit testable; the
// extension only maps Apple's results into the plain samples below.

// MARK: - Categories (V5)

/// One `CategoryActivity` in one segment, before merging.
struct CategoryUsageSample<Token: Hashable> {
    let token: Token?
    let localizedName: String?
    let duration: TimeInterval
}

/// Merge key for a category: its token, or its name when the system withholds the token.
enum CategoryUsageKey<Token: Hashable>: Hashable {
    case token(Token)
    case name(String)
}

/// One row of the Categories breakdown.
struct CategoryUsageEntry<Token: Hashable>: Identifiable {
    let id: CategoryUsageKey<Token>
    let displayName: String
    let token: Token?
    let seconds: Int
}

enum CategoryUsage {

    /// Only used when a category has a token but no name (the row then shows `Label(token)`
    /// anyway) or for sorting.
    static let unknownCategoryName = "Other"

    /// Merges samples across segments the way apps are merged: summed as `TimeInterval`,
    /// rounded once at the end, unidentifiable and zero-time categories dropped, sorted by
    /// seconds descending then name (case-insensitive).
    static func aggregate<Token>(_ samples: [CategoryUsageSample<Token>]) -> [CategoryUsageEntry<Token>] {
        var byKey: [CategoryUsageKey<Token>: (name: String?, token: Token?, duration: TimeInterval)] = [:]
        for sample in samples {
            let name = nonBlank(sample.localizedName)
            let key: CategoryUsageKey<Token>
            if let token = sample.token {
                key = .token(token)
            } else if let name {
                key = .name(name)
            } else {
                continue
            }
            var acc = byKey[key] ?? (name: nil, token: nil, duration: 0)
            acc.name = acc.name ?? name
            acc.token = acc.token ?? sample.token
            acc.duration += max(0, sample.duration)
            byKey[key] = acc
        }

        return byKey
            .map { key, acc in
                CategoryUsageEntry(id: key, displayName: acc.name ?? unknownCategoryName,
                                   token: acc.token, seconds: Int(acc.duration.rounded()))
            }
            .filter { $0.seconds > 0 }
            .sorted { isOrderedBefore($0, $1) }
    }

    /// Per-day figures for Averages (V4). Order is kept, so rows don't jump on a toggle.
    static func averaged<Token>(_ entries: [CategoryUsageEntry<Token>], overDays days: Int) -> [CategoryUsageEntry<Token>] {
        entries.map {
            CategoryUsageEntry(id: $0.id, displayName: $0.displayName, token: $0.token,
                               seconds: UsageAverages.perDay($0.seconds, days: days))
        }
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func isOrderedBefore<Token>(_ a: CategoryUsageEntry<Token>, _ b: CategoryUsageEntry<Token>) -> Bool {
        if a.seconds != b.seconds { return a.seconds > b.seconds }
        return a.displayName.caseInsensitiveCompare(b.displayName) == .orderedAscending
    }
}

/// The breakdown list's source (V5). An enum so Nudge's own categories (#22) can be added as
/// a third case without restructuring the report.
enum UsageBreakdown: Hashable, CaseIterable {
    case apps
    case categories

    var title: String {
        switch self {
        case .apps: "Apps"
        case .categories: "Categories"
        }
    }
}

// MARK: - Totals | Averages (V4)

enum UsageMeasure: Hashable, CaseIterable {
    case totals
    case averages

    var title: String {
        switch self {
        case .totals: "Totals"
        case .averages: "Averages"
        }
    }
}

enum UsageAverages {

    /// The local days `interval` touches, counted on the calendar (not in hours), so DST weeks
    /// are 7 days. The end is exclusive: a range ending at midnight does not touch the next day.
    static func localDays(in interval: DateInterval, calendar: Calendar) -> Int {
        guard interval.duration > 0 else { return 0 }
        let first = calendar.startOfDay(for: interval.start)
        let last = calendar.startOfDay(for: interval.end.addingTimeInterval(-1))
        return max(1, days(from: first, to: last, calendar: calendar) + 1)
    }

    /// V4's "days counted" for a week range: its days up to and including `today` — so the
    /// current week counts Sunday … today and a past week all 7. Future days never count; a
    /// range that has not started counts 0.
    static func daysCounted(in interval: DateInterval, today: Date, calendar: Calendar) -> Int {
        let total = localDays(in: interval, calendar: calendar)
        let first = calendar.startOfDay(for: interval.start)
        let todayStart = calendar.startOfDay(for: today)
        guard total > 0, todayStart >= first else { return 0 }
        return min(total, days(from: first, to: todayStart, calendar: calendar) + 1)
    }

    private static func days(from start: Date, to end: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    /// `total / days`, rounded to the nearest whole unit (halves away from zero). With fewer
    /// than one day there is nothing to divide by, so the total is returned unchanged.
    static func perDay(_ total: Int, days: Int) -> Int {
        guard days > 1 else { return total }
        return Int((Double(total) / Double(days)).rounded())
    }
}

extension DailyUsageSummary {
    /// Per-day figures for Averages (V4): total time, pickups and every row divided by `days`.
    /// Row order and ids are kept, so the list does not reshuffle on a toggle.
    func averaged(overDays days: Int) -> DailyUsageSummary<Token> {
        DailyUsageSummary(
            totalSeconds: UsageAverages.perDay(totalSeconds, days: days),
            totalPickups: UsageAverages.perDay(totalPickups, days: days),
            apps: apps.map {
                AppUsageEntry(id: $0.id, bundleId: $0.bundleId, displayName: $0.displayName, token: $0.token,
                              seconds: UsageAverages.perDay($0.seconds, days: days),
                              pickups: UsageAverages.perDay($0.pickups, days: days))
            }
        )
    }
}

// MARK: - Report

/// What a report covers, as the extension sees it.
///
/// The extension is not told the host's Day | Week mode: a `DeviceActivityReport` passes only its
/// filter. It infers the scope from the filter interval it receives (`DeviceActivityData
/// .segmentInterval`): one local day is a day, more is a week. Week ranges are always the full
/// week (never clipped at today), so this is unambiguous, including on a Sunday.
enum UsageReportScope: Hashable {
    case day
    case week(daysCounted: Int)

    /// V4: Totals | Averages is shown in Week mode only.
    var showsMeasurePicker: Bool {
        if case .week = self { return true }
        return false
    }

    /// `today` (the extension's own clock) sets how many of a week's days count for averages.
    static func infer(from interval: DateInterval?, today: Date, calendar: Calendar) -> UsageReportScope {
        guard let interval, UsageAverages.localDays(in: interval, calendar: calendar) > 1 else { return .day }
        return .week(daysCounted: UsageAverages.daysCounted(in: interval, today: today, calendar: calendar))
    }
}

/// Everything the report view renders. Built once per filter in `makeConfiguration`, which runs
/// under the extension's memory limit, so it holds only the aggregated rows.
struct UsageReport<AppToken: Hashable, CategoryToken: Hashable> {

    /// The figures for one Totals | Averages choice.
    struct Figures {
        let summary: DailyUsageSummary<AppToken>
        let categories: [CategoryUsageEntry<CategoryToken>]
        /// Averages: labels read "Daily Average" and rows end in "/day".
        let isPerDay: Bool
    }

    let scope: UsageReportScope
    let totals: DailyUsageSummary<AppToken>
    let categories: [CategoryUsageEntry<CategoryToken>]

    /// No screen time in the period — the view shows its empty state.
    var isEmpty: Bool { totals.isEmpty }

    static var empty: UsageReport {
        UsageReport(scope: .day, totals: .empty, categories: [])
    }

    static func make(
        segments: [UsageSegmentSample<AppToken>],
        categories: [CategoryUsageSample<CategoryToken>],
        interval: DateInterval?,
        today: Date,
        calendar: Calendar
    ) -> UsageReport {
        UsageReport(
            scope: .infer(from: interval, today: today, calendar: calendar),
            totals: .aggregate(segments),
            categories: CategoryUsage.aggregate(categories)
        )
    }

    /// Day reports always show totals, so an Averages choice left over from a week never
    /// divides a single day.
    func figures(_ measure: UsageMeasure) -> Figures {
        guard measure == .averages, case .week(let days) = scope else {
            return Figures(summary: totals, categories: categories, isPerDay: false)
        }
        return Figures(
            summary: totals.averaged(overDays: days),
            categories: CategoryUsage.averaged(categories, overDays: days),
            isPerDay: true
        )
    }
}

// MARK: - Copy

extension UsageFormatting {
    static func duration(_ seconds: Int, perDay: Bool) -> String {
        perDay ? "\(seconds.formattedDuration)/day" : seconds.formattedDuration
    }

    static func pickups(_ count: Int, perDay: Bool) -> String {
        perDay ? "\(pickups(count))/day" : pickups(count)
    }

    static func headline(perDay: Bool) -> String {
        perDay ? "Daily Average" : "Total Screen Time"
    }

    static func emptyTitle(for scope: UsageReportScope) -> String {
        switch scope {
        case .day: "No usage recorded for this day"
        case .week: "No usage recorded for this week"
        }
    }
}

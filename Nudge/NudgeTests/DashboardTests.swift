import Testing
import Foundation
import FamilyControls
@testable import Nudge

// Phase 2 — Dashboard. The DeviceActivityReport extension cannot be unit tested
// directly (`DeviceActivityData` has no public initializer), so everything it
// computes lives in `Shared/` as pure functions over plain values and is tested
// here. `String` stands in for `ApplicationToken` as the generic token payload.

// MARK: - Helpers

private typealias Sample = AppUsageSample<String>
private typealias Segment = UsageSegmentSample<String>
private typealias Summary = DailyUsageSummary<String>

private func app(
    _ bundleId: String?,
    name: String? = nil,
    token: String? = nil,
    seconds: TimeInterval,
    pickups: Int = 0
) -> Sample {
    Sample(bundleId: bundleId, localizedName: name, token: token, duration: seconds, pickups: pickups)
}

private func segment(total: TimeInterval, pickupsWithoutApp: Int = 0, _ apps: [Sample]) -> Segment {
    Segment(totalDuration: total, pickupsWithoutApp: pickupsWithoutApp, apps: apps)
}

private func calendar(_ tz: String) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: tz)!
    return cal
}

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, in cal: Calendar) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private let enUS = Locale(identifier: "en_US")

// MARK: - Aggregation

@Suite("DailyUsageSummary.aggregate")
@MainActor
struct UsageAggregationTests {

    @Test func emptyInputIsEmptySummary() {
        let summary = Summary.aggregate([])
        #expect(summary.totalSeconds == 0)
        #expect(summary.totalPickups == 0)
        #expect(summary.apps.isEmpty)
        #expect(summary.isEmpty)
    }

    @Test func mergesSameAppAcrossSegments() {
        let summary = Summary.aggregate([
            segment(total: 600, [app("com.instagram.Instagram", seconds: 600, pickups: 2)]),
            segment(total: 900, [app("com.instagram.Instagram", seconds: 900, pickups: 3)]),
        ])
        #expect(summary.apps.count == 1)
        #expect(summary.apps[0].seconds == 1500)
        #expect(summary.apps[0].pickups == 5)
        #expect(summary.apps[0].bundleId == "com.instagram.Instagram")
    }

    @Test func mergesSameAppWithinOneSegment() {
        // The same app can surface under more than one category/device result.
        let summary = Summary.aggregate([
            segment(total: 300, [
                app("com.apple.mobilesafari", seconds: 100, pickups: 1),
                app("com.apple.mobilesafari", seconds: 200, pickups: 1),
            ]),
        ])
        #expect(summary.apps.count == 1)
        #expect(summary.apps[0].seconds == 300)
        #expect(summary.apps[0].pickups == 2)
    }

    @Test func sortsBySecondsDescending() {
        let summary = Summary.aggregate([
            segment(total: 3600, [
                app("com.a.Small", seconds: 60),
                app("com.a.Big", seconds: 2400),
                app("com.a.Medium", seconds: 1140),
            ]),
        ])
        #expect(summary.apps.map(\.displayName) == ["Big", "Medium", "Small"])
    }

    @Test func tiesBreakByDisplayNameCaseInsensitively() {
        let summary = Summary.aggregate([
            segment(total: 900, [
                app("com.z.Zebra", seconds: 300),
                app("com.a.apple", seconds: 300),
                app("com.m.Mango", seconds: 300),
            ]),
        ])
        #expect(summary.apps.map(\.displayName) == ["Apple", "Mango", "Zebra"])
    }

    @Test func totalSecondsComesFromSegmentTotals() {
        // Segment totals include activity not attributed to a listed app.
        let summary = Summary.aggregate([
            segment(total: 1000, [app("com.a.A", seconds: 400)]),
            segment(total: 2000, [app("com.a.A", seconds: 500)]),
        ])
        #expect(summary.totalSeconds == 3000)
    }

    @Test func totalSecondsNeverBelowSumOfApps() {
        let summary = Summary.aggregate([
            segment(total: 100, [app("com.a.A", seconds: 400), app("com.a.B", seconds: 200)]),
        ])
        #expect(summary.totalSeconds == 600)
    }

    @Test func totalSecondsRoundsFractionalDurations() {
        let summary = Summary.aggregate([
            segment(total: 59.6, [app("com.a.A", seconds: 29.8)]),
            segment(total: 0.5, []),
        ])
        #expect(summary.totalSeconds == 60)
        #expect(summary.apps[0].seconds == 30)
    }

    @Test func totalPickupsIncludesPickupsWithoutAppActivity() {
        let summary = Summary.aggregate([
            segment(total: 600, pickupsWithoutApp: 4, [
                app("com.a.A", seconds: 300, pickups: 10),
                app("com.a.B", seconds: 300, pickups: 3),
            ]),
            segment(total: 60, pickupsWithoutApp: 1, [app("com.a.A", seconds: 60, pickups: 2)]),
        ])
        #expect(summary.totalPickups == 20)
    }

    @Test func dropsAppsWithNoTimeAndNoPickups() {
        let summary = Summary.aggregate([
            segment(total: 60, [app("com.a.Used", seconds: 60), app("com.a.Idle", seconds: 0, pickups: 0)]),
        ])
        #expect(summary.apps.map(\.displayName) == ["Used"])
    }

    @Test func keepsAppWithPickupsButNoTime() {
        let summary = Summary.aggregate([
            segment(total: 60, [app("com.a.Used", seconds: 60), app("com.a.Peek", seconds: 0, pickups: 1)]),
        ])
        #expect(summary.apps.map(\.displayName) == ["Used", "Peek"])
    }

    @Test func dropsUnidentifiableAppsButKeepsTheirTimeInTotal() {
        let summary = Summary.aggregate([
            segment(total: 500, [app(nil, seconds: 200), app("com.a.A", seconds: 300)]),
        ])
        #expect(summary.apps.map(\.displayName) == ["A"])
        #expect(summary.totalSeconds == 500)
    }

    @Test func tokenOnlyAppsMergeByToken() {
        let summary = Summary.aggregate([
            segment(total: 100, [app(nil, name: "Secret", token: "tok-1", seconds: 100)]),
            segment(total: 50, [app(nil, name: "Secret", token: "tok-1", seconds: 50)]),
        ])
        #expect(summary.apps.count == 1)
        #expect(summary.apps[0].seconds == 150)
        #expect(summary.apps[0].token == "tok-1")
        #expect(summary.apps[0].bundleId == nil)
    }

    @Test func carriesFirstAvailableTokenAndName() {
        let summary = Summary.aggregate([
            segment(total: 100, [app("com.a.A", seconds: 100)]),
            segment(total: 100, [app("com.a.A", name: "Alpha", token: "tok-a", seconds: 100)]),
        ])
        #expect(summary.apps[0].token == "tok-a")
        #expect(summary.apps[0].displayName == "Alpha")
    }

    @Test func rowIdsAreUnique() {
        let summary = Summary.aggregate([
            segment(total: 300, [
                app("com.a.A", seconds: 100),
                app(nil, token: "tok", seconds: 100),
                app(nil, name: "Named", seconds: 100),
            ]),
        ])
        #expect(Set(summary.apps.map(\.id)).count == 3)
    }

    @Test func zeroUsageDayIsEmpty() {
        let summary = Summary.aggregate([segment(total: 0, pickupsWithoutApp: 2, [])])
        #expect(summary.isEmpty)
    }

    @Test func dayWithUsageIsNotEmpty() {
        let summary = Summary.aggregate([segment(total: 30, [])])
        #expect(!summary.isEmpty)
    }
}

// MARK: - Display name

@Suite("AppUsageEntry.displayName")
@MainActor
struct AppDisplayNameTests {

    @Test func prefersLocalizedName() {
        #expect(AppUsageNaming.displayName(localizedName: "Instagram", bundleId: "com.burbn.instagram") == "Instagram")
    }

    @Test func trimsLocalizedName() {
        #expect(AppUsageNaming.displayName(localizedName: "  Maps \n", bundleId: nil) == "Maps")
    }

    @Test func blankLocalizedNameFallsBackToBundleId() {
        #expect(AppUsageNaming.displayName(localizedName: "   ", bundleId: "com.instagram.Instagram") == "Instagram")
    }

    @Test func usesLastBundleIdComponent() {
        #expect(AppUsageNaming.displayName(localizedName: nil, bundleId: "com.instagram.Instagram") == "Instagram")
    }

    @Test func capitalizesLowercaseLastComponent() {
        #expect(AppUsageNaming.displayName(localizedName: nil, bundleId: "com.google.ios.youtube") == "Youtube")
    }

    @Test func bundleIdWithoutDotsIsUsedWhole() {
        #expect(AppUsageNaming.displayName(localizedName: nil, bundleId: "Safari") == "Safari")
    }

    @Test func trailingDotFallsBackToWholeBundleId() {
        #expect(AppUsageNaming.displayName(localizedName: nil, bundleId: "com.example.") == "com.example.")
    }

    @Test func nothingKnownIsUnknownApp() {
        #expect(AppUsageNaming.displayName(localizedName: nil, bundleId: nil) == "Unknown App")
        #expect(AppUsageNaming.displayName(localizedName: "", bundleId: "") == "Unknown App")
    }
}

// MARK: - Bar geometry

@Suite("UsageBar")
@MainActor
struct UsageBarTests {

    @Test func fractionIsProportionalToTotal() {
        #expect(UsageBar.fraction(seconds: 1800, totalSeconds: 3600) == 0.5)
        #expect(UsageBar.fraction(seconds: 3600, totalSeconds: 3600) == 1.0)
    }

    @Test func fractionIsZeroWhenTotalIsZero() {
        #expect(UsageBar.fraction(seconds: 0, totalSeconds: 0) == 0)
        #expect(UsageBar.fraction(seconds: 120, totalSeconds: 0) == 0)
    }

    @Test func fractionIsZeroForZeroOrNegativeSeconds() {
        #expect(UsageBar.fraction(seconds: 0, totalSeconds: 3600) == 0)
        #expect(UsageBar.fraction(seconds: -5, totalSeconds: 3600) == 0)
    }

    @Test func fractionIsClampedToOne() {
        #expect(UsageBar.fraction(seconds: 7200, totalSeconds: 3600) == 1.0)
    }

    @Test func widthScalesWithFraction() {
        #expect(UsageBar.width(fraction: 0.5, availableWidth: 200) == 100)
    }

    @Test func tinyNonZeroFractionGetsMinimumWidth() {
        #expect(UsageBar.width(fraction: 0.001, availableWidth: 200) == UsageBar.minimumWidth)
        #expect(UsageBar.minimumWidth == 2)
    }

    @Test func zeroFractionHasNoBar() {
        #expect(UsageBar.width(fraction: 0, availableWidth: 200) == 0)
    }

    @Test func widthNeverExceedsAvailableWidth() {
        #expect(UsageBar.width(fraction: 1.0, availableWidth: 200) == 200)
        #expect(UsageBar.width(fraction: 0.5, availableWidth: 1) == 1)
    }

    @Test func zeroAvailableWidthIsZero() {
        #expect(UsageBar.width(fraction: 0.5, availableWidth: 0) == 0)
    }
}

// MARK: - Pickups label

@Suite("UsageFormatting.pickups")
@MainActor
struct PickupsLabelTests {

    @Test func pluralizes() {
        #expect(UsageFormatting.pickups(0) == "0 pickups")
        #expect(UsageFormatting.pickups(1) == "1 pickup")
        #expect(UsageFormatting.pickups(47) == "47 pickups")
    }
}

// MARK: - Spec formattedDuration cases

@Suite("Int.formattedDuration — Phase 2 spec cases")
@MainActor
struct DashboardDurationFormatTests {

    @Test func specExamples() {
        #expect(5400.formattedDuration == "1h 30m")
        #expect(600.formattedDuration == "10m")
        #expect(3660.formattedDuration == "1h 1m")
        #expect(45.formattedDuration == "< 1m")
        #expect(0.formattedDuration == "0m")
    }
}

// MARK: - Day navigation

@Suite("DashboardDay")
@MainActor
struct DashboardDayTests {

    private let cal = calendar("America/Denver")

    // MARK: filterInterval

    @Test func filterIntervalCoversTheWholeLocalDay() {
        let interval = DashboardDay.filterInterval(for: date(2026, 4, 14, 15, 30, in: cal), calendar: cal)
        #expect(interval.start == date(2026, 4, 14, 0, 0, in: cal))
        #expect(interval.end == date(2026, 4, 15, 0, 0, in: cal))
        #expect(interval.duration == 86_400)
    }

    @Test func filterIntervalIsNeverZeroLength() {
        // ADR-045: a zero-length interval returns no data.
        let interval = DashboardDay.filterInterval(for: date(2026, 4, 14, 0, 0, in: cal), calendar: cal)
        #expect(interval.duration > 0)
    }

    @Test func filterIntervalHandlesDSTFallBack() {
        // 2026-11-01 is the US fall-back day: 25 hours long in Denver.
        let interval = DashboardDay.filterInterval(for: date(2026, 11, 1, 12, in: cal), calendar: cal)
        #expect(interval.duration == 25 * 3600)
    }

    @Test func filterIntervalUsesTheCalendarsTimeZone() {
        let utc = calendar("UTC")
        let instant = date(2026, 4, 14, 20, 0, in: cal) // 02:00 UTC on Apr 15
        let interval = DashboardDay.filterInterval(for: instant, calendar: utc)
        #expect(interval.start == date(2026, 4, 15, 0, 0, in: utc))
    }

    // MARK: isToday / title

    @Test func isTodayMatchesSameLocalDayOnly() {
        let now = date(2026, 4, 14, 9, in: cal)
        #expect(DashboardDay.isToday(date(2026, 4, 14, 23, 59, in: cal), today: now, calendar: cal))
        #expect(!DashboardDay.isToday(date(2026, 4, 13, 23, 59, in: cal), today: now, calendar: cal))
    }

    @Test func titleIsTodayForToday() {
        let now = date(2026, 4, 14, in: cal)
        #expect(DashboardDay.title(for: now, today: now, calendar: cal, locale: enUS) == "Today")
    }

    @Test func titleIsYesterdayForYesterday() {
        let now = date(2026, 4, 14, 0, 5, in: cal)
        let day = date(2026, 4, 13, 23, 0, in: cal)
        #expect(DashboardDay.title(for: day, today: now, calendar: cal, locale: enUS) == "Yesterday")
    }

    @Test func titleIsShortDateOtherwise() {
        let now = date(2026, 4, 20, in: cal)
        #expect(DashboardDay.title(for: date(2026, 4, 14, in: cal), today: now, calendar: cal, locale: enUS) == "Apr 14")
    }

    @Test func titleUsesTheCalendarsTimeZone() {
        // 23:30 Denver on Apr 12 is Apr 13 in UTC — the title must follow the calendar.
        let now = date(2026, 4, 20, in: cal)
        let day = date(2026, 4, 12, 23, 30, in: cal)
        #expect(DashboardDay.title(for: day, today: now, calendar: cal, locale: enUS) == "Apr 12")
    }

    // MARK: earliest / clamp

    @Test func earliestDayIsThirtyDaysBack() {
        let now = date(2026, 4, 30, 18, in: cal)
        #expect(DashboardDay.earliestDay(today: now, calendar: cal) == date(2026, 3, 31, 0, 0, in: cal))
        #expect(DashboardDay.maxDaysBack == 30)
    }

    @Test func clampNormalizesToStartOfDay() {
        let now = date(2026, 4, 20, in: cal)
        let clamped = DashboardDay.clamp(date(2026, 4, 14, 17, 45, in: cal), today: now, calendar: cal)
        #expect(clamped == date(2026, 4, 14, 0, 0, in: cal))
    }

    @Test func clampPullsFutureDatesBackToToday() {
        let now = date(2026, 4, 20, 8, in: cal)
        let clamped = DashboardDay.clamp(date(2026, 4, 25, in: cal), today: now, calendar: cal)
        #expect(clamped == date(2026, 4, 20, 0, 0, in: cal))
    }

    @Test func clampPullsOldDatesUpToEarliest() {
        let now = date(2026, 4, 20, in: cal)
        let clamped = DashboardDay.clamp(date(2026, 1, 1, in: cal), today: now, calendar: cal)
        #expect(clamped == DashboardDay.earliestDay(today: now, calendar: cal))
    }

    // MARK: step / bounds

    @Test func stepBackMovesOneDay() {
        let now = date(2026, 4, 20, in: cal)
        let day = DashboardDay.step(date(2026, 4, 20, in: cal), by: -1, today: now, calendar: cal)
        #expect(day == date(2026, 4, 19, 0, 0, in: cal))
    }

    @Test func stepForwardMovesOneDay() {
        let now = date(2026, 4, 20, in: cal)
        let day = DashboardDay.step(date(2026, 4, 14, in: cal), by: 1, today: now, calendar: cal)
        #expect(day == date(2026, 4, 15, 0, 0, in: cal))
    }

    @Test func stepForwardStopsAtToday() {
        let now = date(2026, 4, 20, in: cal)
        let day = DashboardDay.step(date(2026, 4, 20, in: cal), by: 1, today: now, calendar: cal)
        #expect(day == date(2026, 4, 20, 0, 0, in: cal))
    }

    @Test func stepBackStopsAtEarliest() {
        let now = date(2026, 4, 20, in: cal)
        let earliest = DashboardDay.earliestDay(today: now, calendar: cal)
        #expect(DashboardDay.step(earliest, by: -1, today: now, calendar: cal) == earliest)
    }

    @Test func stepAcrossDSTLandsOnMidnight() {
        let now = date(2026, 11, 5, in: cal)
        let day = DashboardDay.step(date(2026, 11, 2, 0, 0, in: cal), by: -1, today: now, calendar: cal)
        #expect(day == date(2026, 11, 1, 0, 0, in: cal))
    }

    @Test func cannotStepForwardFromToday() {
        let now = date(2026, 4, 20, 9, in: cal)
        #expect(!DashboardDay.canStepForward(from: date(2026, 4, 20, 0, 0, in: cal), today: now, calendar: cal))
        #expect(DashboardDay.canStepForward(from: date(2026, 4, 19, in: cal), today: now, calendar: cal))
    }

    @Test func cannotStepBackFromEarliest() {
        let now = date(2026, 4, 20, in: cal)
        let earliest = DashboardDay.earliestDay(today: now, calendar: cal)
        let dayAfter = cal.date(byAdding: .day, value: 1, to: earliest)!
        #expect(!DashboardDay.canStepBack(from: earliest, today: now, calendar: cal))
        #expect(DashboardDay.canStepBack(from: dayAfter, today: now, calendar: cal))
    }

    @Test func todayCanStepBack() {
        let now = date(2026, 4, 20, in: cal)
        #expect(DashboardDay.canStepBack(from: now, today: now, calendar: cal))
    }

    @Test func exactlyThirtyStepsBackReachesTheLimit() {
        let now = date(2026, 4, 20, in: cal)
        var day = DashboardDay.clamp(now, today: now, calendar: cal)
        var steps = 0
        while DashboardDay.canStepBack(from: day, today: now, calendar: cal) {
            day = DashboardDay.step(day, by: -1, today: now, calendar: cal)
            steps += 1
            if steps > 100 { break }
        }
        #expect(steps == 30)
    }
}

// MARK: - Availability

@Suite("DashboardAvailability")
@MainActor
struct DashboardAvailabilityTests {

    @Test func unauthorizedWinsOverInactiveMonitoring() {
        #expect(DashboardAvailability.resolve(isAuthorized: false, isMonitoringActive: false) == .needsAuthorization)
        #expect(DashboardAvailability.resolve(isAuthorized: false, isMonitoringActive: true) == .needsAuthorization)
    }

    @Test func authorizedButNotMonitoringIsInactive() {
        #expect(DashboardAvailability.resolve(isAuthorized: true, isMonitoringActive: false) == .trackingInactive)
    }

    @Test func authorizedAndMonitoringIsReady() {
        #expect(DashboardAvailability.resolve(isAuthorized: true, isMonitoringActive: true) == .ready)
    }

    @Test func onlyApprovedStatusesCountAsAuthorized() {
        #expect(DashboardAvailability.isAuthorized(.approved))
        #expect(!DashboardAvailability.isAuthorized(.denied))
        #expect(!DashboardAvailability.isAuthorized(.notDetermined))
    }
}

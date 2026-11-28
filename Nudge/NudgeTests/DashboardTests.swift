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

/// Phase 2 D2 (2026-11-27): availability resolves from the shared `PermissionStatusStore`'s
/// Screen Time status, plus whether monitoring is registered.
@Suite("DashboardAvailability")
@MainActor
struct DashboardAvailabilityTests {

    private let statuses: [PermissionStatus] = [.notDetermined, .denied, .granted]

    /// Before the store's first refresh nothing is known, whatever it currently holds.
    @Test func notLoadedIsLoadingForEveryInput() {
        for status in statuses {
            for monitoring in [false, true] {
                #expect(DashboardAvailability.resolve(screenTime: status, isLoaded: false,
                                                      isMonitoringActive: monitoring) == .loading,
                        "\(status) monitoring \(monitoring)")
            }
        }
    }

    @Test func notGrantedNeedsAuthorizationEvenWhileMonitoring() {
        for status in [PermissionStatus.notDetermined, .denied] {
            for monitoring in [false, true] {
                #expect(DashboardAvailability.resolve(screenTime: status, isLoaded: true,
                                                      isMonitoringActive: monitoring) == .needsAuthorization,
                        "\(status) monitoring \(monitoring)")
            }
        }
    }

    @Test func grantedButNotMonitoringIsInactive() {
        #expect(DashboardAvailability.resolve(screenTime: .granted, isLoaded: true,
                                              isMonitoringActive: false) == .trackingInactive)
    }

    @Test func grantedAndMonitoringIsReady() {
        #expect(DashboardAvailability.resolve(screenTime: .granted, isLoaded: true,
                                              isMonitoringActive: true) == .ready)
    }

    /// D3: the report is rebuilt once when it becomes showable (e.g. right after Screen Time
    /// is granted and monitoring registers), never while it stays showable or stays hidden.
    @Test func refreshesOnlyOnTransitionIntoReady() {
        let all: [DashboardAvailability] = [.loading, .needsAuthorization, .trackingInactive, .ready]
        for from in all {
            for to in all {
                let expected = to == .ready && from != .ready
                #expect(DashboardAvailability.shouldRefreshOnTransition(from: from, to: to) == expected,
                        "\(from) -> \(to)")
            }
        }
    }
}

// MARK: - Dashboard v2 (2026-11-27): Day | Week, date picker, Totals | Averages, Categories

private typealias CategorySample = CategoryUsageSample<String>
private typealias Report = UsageReport<String, String>

private func category(_ token: String?, name: String? = nil, seconds: TimeInterval) -> CategorySample {
    CategorySample(token: token, localizedName: name, duration: seconds)
}

/// V2/V3 date math. "Today" is Friday Nov 27 2026, 15:00 in Denver unless a test says otherwise,
/// so the selectable range starts Wed Oct 28 and the current week is Sun Nov 22 – Sat Nov 28.
@Suite("DashboardCalendar")
@MainActor
struct DashboardCalendarTests {

    private let cal = calendar("America/Denver")
    private var now: Date { date(2026, 11, 27, 15, in: cal) }
    private var nav: DashboardCalendar { DashboardCalendar(calendar: cal, today: now) }

    private func midnight(_ y: Int, _ m: Int, _ d: Int) -> Date { date(y, m, d, 0, 0, in: cal) }
    private func week(_ y: Int, _ m: Int, _ d: Int) -> DashboardPeriod { DashboardPeriod(mode: .week, start: midnight(y, m, d)) }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> DashboardPeriod { DashboardPeriod(mode: .day, start: midnight(y, m, d)) }

    // MARK: week start

    @Test func weeksStartOnSundayByDefault() {
        #expect(DashboardCalendar.defaultFirstWeekday == 1)
        for d in 22...28 {
            #expect(nav.weekStart(containing: date(2026, 11, d, 18, in: cal)) == midnight(2026, 11, 22), "Nov \(d)")
        }
    }

    @Test func weekStartFollowsTheFirstWeekdayParameter() {
        let monday = DashboardCalendar(calendar: cal, today: now, firstWeekday: 2)
        #expect(monday.weekStart(containing: date(2026, 11, 22, in: cal)) == midnight(2026, 11, 16))
        #expect(monday.weekStart(containing: date(2026, 11, 23, in: cal)) == midnight(2026, 11, 23))
    }

    @Test func periodContainingNormalizesToTheDayOrWeekStart() {
        #expect(nav.period(containing: date(2026, 11, 18, 14, in: cal), mode: .day) == day(2026, 11, 18))
        #expect(nav.period(containing: date(2026, 11, 18, 14, in: cal), mode: .week) == week(2026, 11, 15))
    }

    // MARK: filter interval

    @Test func dayFilterIsTheWholeLocalDay() {
        let interval = nav.filterInterval(for: day(2026, 11, 25))
        #expect(interval.start == midnight(2026, 11, 25))
        #expect(interval.end == midnight(2026, 11, 26))
    }

    @Test func pastWeekFilterRunsSundayToNextSunday() {
        let interval = nav.filterInterval(for: week(2026, 11, 15))
        #expect(interval.start == midnight(2026, 11, 15))
        #expect(interval.end == midnight(2026, 11, 22))
        #expect(interval.duration == 7 * 86_400)
    }

    /// Not clipped at today, so a week's range never looks like a single day (scope inference).
    @Test func currentWeekFilterIsTheWholeWeek() {
        let interval = nav.filterInterval(for: week(2026, 11, 22))
        #expect(interval.start == midnight(2026, 11, 22))
        #expect(interval.end == midnight(2026, 11, 29))
    }

    @Test func currentWeekOnSundayIsStillTheWholeWeek() {
        let sunday = DashboardCalendar(calendar: cal, today: date(2026, 11, 22, 0, 0, in: cal))
        let interval = sunday.filterInterval(for: week(2026, 11, 22))
        #expect(interval.start == midnight(2026, 11, 22))
        #expect(interval.end == midnight(2026, 11, 29))
    }

    @Test func weekFilterAcrossDSTFallBackIsSevenLocalDays() {
        // 2026-11-01 (a Sunday) is 25 hours long in Denver.
        let interval = nav.filterInterval(for: week(2026, 11, 1))
        #expect(interval.start == midnight(2026, 11, 1))
        #expect(interval.end == midnight(2026, 11, 8))
        #expect(interval.duration == 7 * 86_400 + 3600)
    }

    @Test func weekFilterAcrossDSTSpringForwardIsSevenLocalDays() {
        // 2026-03-08 (a Sunday) is 23 hours long in Denver.
        let march = DashboardCalendar(calendar: cal, today: date(2026, 3, 20, in: cal))
        let interval = march.filterInterval(for: week(2026, 3, 8))
        #expect(interval.start == midnight(2026, 3, 8))
        #expect(interval.end == midnight(2026, 3, 15))
        #expect(interval.duration == 7 * 86_400 - 3600)
    }

    @Test func weekFilterSpansMonths() {
        let december = DashboardCalendar(calendar: cal, today: date(2026, 12, 10, in: cal))
        let interval = december.filterInterval(for: week(2026, 11, 29))
        #expect(interval.start == midnight(2026, 11, 29))
        #expect(interval.end == midnight(2026, 12, 6))
    }

    @Test func weekFilterSpansYears() {
        let january = DashboardCalendar(calendar: cal, today: date(2027, 1, 10, in: cal))
        let interval = january.filterInterval(for: week(2026, 12, 27))
        #expect(interval.start == midnight(2026, 12, 27))
        #expect(interval.end == midnight(2027, 1, 3))
    }

    // MARK: titles

    @Test func dayTitlesAreUnchanged() {
        #expect(nav.title(for: day(2026, 11, 27), locale: enUS) == "Today")
        #expect(nav.title(for: day(2026, 11, 26), locale: enUS) == "Yesterday")
        #expect(nav.title(for: day(2026, 11, 25), locale: enUS) == "Nov 25")
    }

    @Test func weekTitleWithinAMonth() {
        #expect(nav.title(for: week(2026, 11, 15), locale: enUS) == "Nov 15 – 21")
    }

    @Test func currentWeekTitleIsStillADateRange() {
        #expect(nav.title(for: week(2026, 11, 22), locale: enUS) == "Nov 22 – 28")
    }

    @Test func weekTitleAcrossMonths() {
        let december = DashboardCalendar(calendar: cal, today: date(2026, 12, 10, in: cal))
        #expect(december.title(for: week(2026, 11, 29), locale: enUS) == "Nov 29 – Dec 5")
        let fall2025 = DashboardCalendar(calendar: cal, today: date(2025, 11, 10, in: cal))
        #expect(fall2025.title(for: week(2025, 10, 26), locale: enUS) == "Oct 26 – Nov 1")
    }

    @Test func weekTitleAcrossYears() {
        let january = DashboardCalendar(calendar: cal, today: date(2027, 1, 10, in: cal))
        #expect(january.title(for: week(2026, 12, 27), locale: enUS) == "Dec 27 – Jan 2")
    }

    // MARK: stepping and bounds

    @Test func weekStepsOneWeek() {
        #expect(nav.step(week(2026, 11, 22), by: -1) == week(2026, 11, 15))
        #expect(nav.step(week(2026, 11, 15), by: 1) == week(2026, 11, 22))
    }

    @Test func dayStepsOneDay() {
        #expect(nav.step(day(2026, 11, 27), by: -1) == day(2026, 11, 26))
        #expect(nav.step(day(2026, 11, 27), by: 1) == day(2026, 11, 27))
    }

    @Test func cannotStepForwardOnTheCurrentWeek() {
        #expect(!nav.canStepForward(week(2026, 11, 22)))
        #expect(nav.canStepForward(week(2026, 11, 15)))
        #expect(nav.step(week(2026, 11, 22), by: 1) == week(2026, 11, 22))
    }

    @Test func earliestWeekIsTheOneContainingTheEarliestDay() {
        // Earliest day is Wed Oct 28, so the week of Sun Oct 25 is reachable; Oct 18 is not.
        #expect(nav.canStepBack(week(2026, 11, 1)))
        #expect(nav.step(week(2026, 11, 1), by: -1) == week(2026, 10, 25))
        #expect(!nav.canStepBack(week(2026, 10, 25)))
        #expect(nav.step(week(2026, 10, 25), by: -1) == week(2026, 10, 25))
    }

    @Test func fourStepsBackReachTheEarliestWeek() {
        var period = week(2026, 11, 22)
        var steps = 0
        while nav.canStepBack(period), steps < 100 {
            period = nav.step(period, by: -1)
            steps += 1
        }
        #expect(steps == 4)
        #expect(period == week(2026, 10, 25))
    }

    @Test func weekStepsAcrossDSTLandOnSundayMidnight() {
        #expect(nav.step(week(2026, 11, 8), by: -1) == week(2026, 11, 1))
        #expect(nav.step(week(2026, 11, 1), by: 1) == week(2026, 11, 8))
    }

    @Test func clampPullsWeeksIntoRange() {
        #expect(nav.clamp(week(2026, 9, 6)) == week(2026, 10, 25))
        #expect(nav.clamp(week(2026, 12, 20)) == week(2026, 11, 22))
        #expect(nav.clamp(DashboardPeriod(mode: .week, start: date(2026, 11, 18, 9, in: cal))) == week(2026, 11, 15))
    }

    @Test func clampKeepsDayBehavior() {
        #expect(nav.clamp(day(2026, 12, 1)) == day(2026, 11, 27))
        #expect(nav.clamp(day(2026, 9, 1)) == day(2026, 10, 28))
    }

    // MARK: Day <-> Week

    @Test func dayToWeekShowsTheWeekContainingTheDay() {
        #expect(nav.switching(day(2026, 11, 18), to: .week) == week(2026, 11, 15))
        #expect(nav.switching(day(2026, 10, 28), to: .week) == week(2026, 10, 25))
    }

    @Test func weekToDaySelectsTodayInTheCurrentWeek() {
        #expect(nav.switching(week(2026, 11, 22), to: .day) == day(2026, 11, 27))
    }

    @Test func weekToDaySelectsSaturdayInAPastWeek() {
        #expect(nav.switching(week(2026, 11, 15), to: .day) == day(2026, 11, 21))
        #expect(nav.switching(week(2026, 10, 25), to: .day) == day(2026, 10, 31))
    }

    @Test func switchingToTheSameModeKeepsTheSelection() {
        #expect(nav.switching(day(2026, 11, 18), to: .day) == day(2026, 11, 18))
        #expect(nav.switching(week(2026, 11, 15), to: .week) == week(2026, 11, 15))
    }

    // MARK: date picker

    @Test func pickerRangeIsTheLastThirtyDaysThroughToday() {
        let range = nav.pickerRange
        #expect(range.lowerBound == midnight(2026, 10, 28))
        #expect(range.contains(midnight(2026, 11, 27)))
        #expect(range.contains(date(2026, 11, 27, 23, 59, in: cal)))
        #expect(!range.contains(midnight(2026, 11, 28)))
        #expect(!range.contains(date(2026, 10, 27, 23, 59, in: cal)))
    }

    @Test func pickerStartsOnTheSelectedDayOrTheWeeksDay() {
        #expect(nav.pickerSelection(for: day(2026, 11, 18)) == midnight(2026, 11, 18))
        #expect(nav.pickerSelection(for: week(2026, 11, 22)) == midnight(2026, 11, 27))
        #expect(nav.pickerSelection(for: week(2026, 11, 15)) == midnight(2026, 11, 21))
        #expect(nav.pickerRange.contains(nav.pickerSelection(for: week(2026, 10, 25))))
    }

    @Test func pickingADateSelectsItsDayOrWeek() {
        let picked = date(2026, 11, 18, 14, in: cal)
        #expect(nav.select(picked, mode: .day) == day(2026, 11, 18))
        #expect(nav.select(picked, mode: .week) == week(2026, 11, 15))
    }

    @Test func pickingOutOfRangeIsClamped() {
        #expect(nav.select(date(2026, 12, 3, in: cal), mode: .day) == day(2026, 11, 27))
        #expect(nav.select(date(2026, 9, 3, in: cal), mode: .week) == week(2026, 10, 25))
    }

    // MARK: enums

    @Test func modesAreDayThenWeek() {
        #expect(DashboardMode.allCases == [.day, .week])
        #expect(DashboardMode.day.title == "Day")
        #expect(DashboardMode.week.title == "Week")
    }
}

// MARK: - Refresh policy (V1)

@Suite("ReportRebuildPolicy")
@MainActor
struct ReportRebuildPolicyTests {

    private let t0 = ContinuousClock.now

    @Test func debounceIsAbout400ms() {
        #expect(ReportRebuildPolicy.defaultDebounce == .milliseconds(400))
    }

    @Test func nothingFiresWithoutARequest() {
        var policy = ReportRebuildPolicy()
        #expect(policy.remainingDelay(at: t0) == nil)
        let fired1 = policy.fire(at: t0 + .seconds(5))
        #expect(!fired1)
    }

    @Test func firesOnlyAfterTheDebounce() {
        var policy = ReportRebuildPolicy()
        policy.request(at: t0)
        let fired2 = policy.fire(at: t0 + .milliseconds(399))
        #expect(!fired2)
        let fired3 = policy.fire(at: t0 + .milliseconds(400))
        #expect(fired3)
    }

    @Test func firesOncePerRequest() {
        var policy = ReportRebuildPolicy()
        policy.request(at: t0)
        let fired4 = policy.fire(at: t0 + .milliseconds(500))
        #expect(fired4)
        let fired5 = policy.fire(at: t0 + .milliseconds(900))
        #expect(!fired5)
    }

    @Test func backToBackRequestsCoalesceIntoOneRebuild() {
        var policy = ReportRebuildPolicy()
        policy.request(at: t0)
        policy.request(at: t0 + .milliseconds(100))
        policy.request(at: t0 + .milliseconds(300))
        // The deadline moved to 400 ms after the last request.
        let fired6 = policy.fire(at: t0 + .milliseconds(500))
        #expect(!fired6)
        let fired7 = policy.fire(at: t0 + .milliseconds(700))
        #expect(fired7)
        let fired8 = policy.fire(at: t0 + .milliseconds(800))
        #expect(!fired8)
    }

    @Test func remainingDelayCountsDownToZero() {
        var policy = ReportRebuildPolicy()
        policy.request(at: t0)
        #expect(policy.remainingDelay(at: t0 + .milliseconds(100)) == .milliseconds(300))
        #expect(policy.remainingDelay(at: t0 + .seconds(2)) == .zero)
    }

    @Test func everyRequestChangesTheGeneration() {
        var policy = ReportRebuildPolicy()
        let initial = policy.generation
        policy.request(at: t0)
        let first = policy.generation
        policy.request(at: t0)
        #expect(first != initial)
        #expect(policy.generation != first)
    }

    @Test func cancelDropsThePendingRebuild() {
        var policy = ReportRebuildPolicy()
        policy.request(at: t0)
        policy.cancel()
        #expect(policy.remainingDelay(at: t0) == nil)
        let fired9 = policy.fire(at: t0 + .seconds(1))
        #expect(!fired9)
    }

    @Test func aRequestAfterARebuildSchedulesAnother() {
        var policy = ReportRebuildPolicy()
        policy.request(at: t0)
        let fired10 = policy.fire(at: t0 + .milliseconds(400))
        #expect(fired10)
        policy.request(at: t0 + .seconds(1))
        let fired11 = policy.fire(at: t0 + .milliseconds(1400))
        #expect(fired11)
    }
}

// MARK: - Days counted and averages (V4)

@Suite("UsageAverages")
@MainActor
struct UsageAveragesTests {

    private let cal = calendar("America/Denver")
    private var now: Date { date(2026, 11, 27, 15, in: cal) }
    private var nav: DashboardCalendar { DashboardCalendar(calendar: cal, today: now) }
    private func week(_ y: Int, _ m: Int, _ d: Int) -> DashboardPeriod {
        DashboardPeriod(mode: .week, start: date(y, m, d, 0, 0, in: cal))
    }

    private func counted(_ period: DashboardPeriod, today: Date) -> Int {
        UsageAverages.daysCounted(in: nav.filterInterval(for: period), today: today, calendar: cal)
    }

    @Test func pastWeekCountsSevenDays() {
        #expect(counted(week(2026, 11, 15), today: now) == 7)
        #expect(counted(week(2026, 10, 25), today: now) == 7)
    }

    @Test func currentWeekCountsDaysThroughToday() {
        // Sun Nov 22 … Fri Nov 27; Saturday is still in the future.
        #expect(counted(week(2026, 11, 22), today: now) == 6)
    }

    @Test func currentWeekOnSundayCountsOneDay() {
        #expect(counted(week(2026, 11, 22), today: date(2026, 11, 22, 0, 0, in: cal)) == 1)
        #expect(counted(week(2026, 11, 22), today: date(2026, 11, 22, 23, 59, in: cal)) == 1)
    }

    @Test func currentWeekOnSaturdayCountsSevenDays() {
        #expect(counted(week(2026, 11, 22), today: date(2026, 11, 28, 23, 59, in: cal)) == 7)
    }

    @Test func aWeekThatHasNotStartedCountsNothing() {
        #expect(counted(week(2026, 11, 29), today: now) == 0)
    }

    @Test func dstWeeksCountSevenDays() {
        #expect(counted(week(2026, 11, 1), today: now) == 7)
        let march = DashboardCalendar(calendar: cal, today: date(2026, 3, 20, in: cal))
        let marchWeek = march.filterInterval(for: week(2026, 3, 8))
        #expect(UsageAverages.daysCounted(in: marchWeek, today: date(2026, 3, 20, in: cal), calendar: cal) == 7)
    }

    @Test func dstWeekInProgressCountsCalendarDays() {
        // Fall-back Sunday is 25 h long; Tuesday is still day 3.
        #expect(counted(week(2026, 11, 1), today: date(2026, 11, 3, 1, in: cal)) == 3)
    }

    @Test func singleDayCountsOne() {
        #expect(UsageAverages.daysCounted(in: DashboardDay.filterInterval(for: now, calendar: cal), today: now, calendar: cal) == 1)
    }

    @Test func zeroLengthIntervalCountsNothing() {
        #expect(UsageAverages.daysCounted(in: DateInterval(start: now, duration: 0), today: now, calendar: cal) == 0)
    }

    @Test func localDaysCountsTheRangesDays() {
        #expect(UsageAverages.localDays(in: nav.filterInterval(for: week(2026, 11, 22)), calendar: cal) == 7)
        #expect(UsageAverages.localDays(in: DashboardDay.filterInterval(for: now, calendar: cal), calendar: cal) == 1)
    }

    @Test func perDayRoundsToNearest() {
        #expect(UsageAverages.perDay(100, days: 7) == 14)   // 14.29
        #expect(UsageAverages.perDay(10, days: 4) == 3)     // 2.5 rounds up
        #expect(UsageAverages.perDay(9, days: 4) == 2)      // 2.25
        #expect(UsageAverages.perDay(0, days: 7) == 0)
    }

    @Test func perDayWithNoDaysLeavesTheValue() {
        #expect(UsageAverages.perDay(7, days: 0) == 7)
        #expect(UsageAverages.perDay(7, days: 1) == 7)
    }

    @Test func averagedSummaryDividesTotalsAndRowsAndKeepsOrder() {
        let totals = Summary.aggregate([
            segment(total: 7000, pickupsWithoutApp: 7, [
                app("com.a.Big", seconds: 4200, pickups: 14),
                app("com.a.Small", seconds: 700, pickups: 0),
            ]),
        ])
        let averaged = totals.averaged(overDays: 7)
        #expect(averaged.totalSeconds == 1000)
        #expect(averaged.totalPickups == 3)
        #expect(averaged.apps.map(\.displayName) == ["Big", "Small"])
        #expect(averaged.apps.map(\.seconds) == [600, 100])
        #expect(averaged.apps.map(\.pickups) == [2, 0])
        #expect(averaged.apps.map(\.id) == totals.apps.map(\.id))
    }
}

// MARK: - Report scope (how the extension knows Day vs Week)

@Suite("UsageReportScope")
@MainActor
struct UsageReportScopeTests {

    private let cal = calendar("America/Denver")
    private var nav: DashboardCalendar { DashboardCalendar(calendar: cal, today: date(2026, 11, 27, 15, in: cal)) }

    private var today: Date { date(2026, 11, 27, 15, in: cal) }
    private func range(_ mode: DashboardMode, _ d: Int) -> DateInterval {
        nav.filterInterval(for: DashboardPeriod(mode: mode, start: date(2026, 11, d, 0, 0, in: cal)))
    }

    @Test func aDayIntervalIsDayScope() {
        #expect(UsageReportScope.infer(from: range(.day, 25), today: today, calendar: cal) == .day)
        #expect(UsageReportScope.infer(from: range(.day, 22), today: today, calendar: cal) == .day) // a Sunday
    }

    @Test func aWeekIntervalIsWeekScopeWithDaysCounted() {
        #expect(UsageReportScope.infer(from: range(.week, 15), today: today, calendar: cal) == .week(daysCounted: 7))
        #expect(UsageReportScope.infer(from: range(.week, 22), today: today, calendar: cal) == .week(daysCounted: 6))
    }

    /// The current week on its Sunday is a full week range, so it is never mistaken for a day.
    @Test func theCurrentWeekOnSundayIsAWeek() {
        let sunday = date(2026, 11, 22, 9, in: cal)
        let interval = DashboardCalendar(calendar: cal, today: sunday)
            .filterInterval(for: DashboardPeriod(mode: .week, start: date(2026, 11, 22, 0, 0, in: cal)))
        #expect(UsageReportScope.infer(from: interval, today: sunday, calendar: cal) == .week(daysCounted: 1))
    }

    @Test func todayOnASundayIsADay() {
        let sunday = date(2026, 11, 22, 9, in: cal)
        let interval = DashboardCalendar(calendar: cal, today: sunday)
            .filterInterval(for: DashboardPeriod(mode: .day, start: date(2026, 11, 22, 0, 0, in: cal)))
        #expect(UsageReportScope.infer(from: interval, today: sunday, calendar: cal) == .day)
    }

    @Test func noIntervalIsDayScope() {
        #expect(UsageReportScope.infer(from: nil, today: today, calendar: cal) == .day)
    }

    @Test func onlyWeeksShowTheMeasureControl() {
        #expect(!UsageReportScope.day.showsMeasurePicker)
        #expect(UsageReportScope.week(daysCounted: 3).showsMeasurePicker)
    }
}

// MARK: - Categories (V5)

@Suite("CategoryUsage.aggregate")
@MainActor
struct CategoryAggregationTests {

    @Test func emptyInputHasNoCategories() {
        #expect(CategoryUsage.aggregate([CategorySample]()).isEmpty)
    }

    @Test func mergesTheSameCategoryByToken() throws {
        let entries = CategoryUsage.aggregate([
            category("social", name: "Social", seconds: 600),
            category("social", name: "Social", seconds: 900),
        ])
        #expect(entries.count == 1)
        let first = try #require(entries.first)
        #expect(first.seconds == 1500)
        #expect(first.token == "social")
        #expect(first.displayName == "Social")
    }

    @Test func mergesByNameWhenTheTokenIsMissing() throws {
        let entries = CategoryUsage.aggregate([
            category(nil, name: "Games", seconds: 60),
            category(nil, name: " Games ", seconds: 60),
        ])
        #expect(entries.count == 1)
        let first = try #require(entries.first)
        #expect(first.seconds == 120)
        #expect(first.token == nil)
    }

    @Test func dropsUnidentifiableAndIdleCategories() {
        let entries = CategoryUsage.aggregate([
            category(nil, name: nil, seconds: 500),
            category("idle", name: "Idle", seconds: 0),
            category("used", name: "Used", seconds: 10),
        ])
        #expect(entries.map(\.displayName) == ["Used"])
    }

    @Test func sortsBySecondsThenName() {
        let entries = CategoryUsage.aggregate([
            category("b", name: "beta", seconds: 300),
            category("a", name: "Alpha", seconds: 300),
            category("c", name: "Gamma", seconds: 900),
        ])
        #expect(entries.map(\.displayName) == ["Gamma", "Alpha", "beta"])
    }

    @Test func roundsOnceAfterSumming() throws {
        let entries = CategoryUsage.aggregate([
            category("x", seconds: 29.8),
            category("x", seconds: 0.4),
        ])
        let first = try #require(entries.first)
        #expect(first.seconds == 30)
    }

    @Test func tokenWithoutNameUsesTheFallbackName() throws {
        let entries = CategoryUsage.aggregate([category("x", name: nil, seconds: 60)])
        let first = try #require(entries.first)
        #expect(first.displayName == CategoryUsage.unknownCategoryName)
        #expect(CategoryUsage.unknownCategoryName == "Other")
    }

    @Test func rowIdsAreUnique() {
        let entries = CategoryUsage.aggregate([
            category("x", name: "Same", seconds: 60),
            category(nil, name: "Same", seconds: 60),
        ])
        #expect(Set(entries.map(\.id)).count == 2)
    }

    @Test func averagedEntriesDivideSecondsAndKeepOrder() {
        let entries = CategoryUsage.aggregate([
            category("a", name: "A", seconds: 700),
            category("b", name: "B", seconds: 70),
        ])
        let averaged = CategoryUsage.averaged(entries, overDays: 7)
        #expect(averaged.map(\.seconds) == [100, 10])
        #expect(averaged.map(\.id) == entries.map(\.id))
    }

    @Test func breakdownsAreAppsThenCategories() {
        #expect(UsageBreakdown.allCases == [.apps, .categories])
        #expect(UsageBreakdown.apps.title == "Apps")
        #expect(UsageBreakdown.categories.title == "Categories")
    }
}

// MARK: - Report figures (V4 + V5 together)

@Suite("UsageReport")
@MainActor
struct UsageReportTests {

    private let cal = calendar("America/Denver")

    private func report(days: Int?) -> Report {
        let start = date(2026, 11, 15, 0, 0, in: cal)
        let interval = days.map { DateInterval(start: start, end: cal.date(byAdding: .day, value: $0, to: start)!) }
        return Report.make(
            segments: [segment(total: 7000, pickupsWithoutApp: 0, [app("com.a.A", seconds: 7000, pickups: 70)])],
            categories: [category("social", name: "Social", seconds: 7000)],
            interval: interval,
            today: date(2026, 11, 27, 15, in: cal),
            calendar: cal
        )
    }

    @Test func makeAggregatesAppsCategoriesAndScope() {
        let week = report(days: 7)
        #expect(week.scope == .week(daysCounted: 7))
        #expect(week.totals.totalSeconds == 7000)
        #expect(week.categories.map(\.seconds) == [7000])
        #expect(!week.isEmpty)
        #expect(report(days: 1).scope == .day)
    }

    @Test func emptyReportIsEmptyDay() {
        #expect(Report.empty.isEmpty)
        #expect(Report.empty.scope == .day)
    }

    @Test func totalsShowTheRawFigures() {
        let figures = report(days: 7).figures(.totals)
        #expect(!figures.isPerDay)
        #expect(figures.summary.totalSeconds == 7000)
        #expect(figures.categories.map(\.seconds) == [7000])
    }

    @Test func weekAveragesDivideByDaysCounted() {
        let figures = report(days: 7).figures(.averages)
        #expect(figures.isPerDay)
        #expect(figures.summary.totalSeconds == 1000)
        #expect(figures.summary.totalPickups == 10)
        #expect(figures.summary.apps.map(\.seconds) == [1000])
        #expect(figures.categories.map(\.seconds) == [1000])
    }

    @Test func dayReportsAlwaysShowTotals() {
        // A selection left on Averages from Week mode must not divide a single day.
        let figures = report(days: 1).figures(.averages)
        #expect(!figures.isPerDay)
        #expect(figures.summary.totalSeconds == 7000)
    }

    @Test func measuresAreTotalsThenAverages() {
        #expect(UsageMeasure.allCases == [.totals, .averages])
        #expect(UsageMeasure.totals.title == "Totals")
        #expect(UsageMeasure.averages.title == "Averages")
    }
}

// MARK: - Report copy

@Suite("UsageFormatting — v2 copy")
@MainActor
struct UsageReportCopyTests {

    @Test func durationsGetAPerDaySuffixInAverages() {
        #expect(UsageFormatting.duration(3660, perDay: false) == "1h 1m")
        #expect(UsageFormatting.duration(3660, perDay: true) == "1h 1m/day")
        #expect(UsageFormatting.duration(45, perDay: true) == "< 1m/day")
    }

    @Test func pickupsGetAPerDaySuffixInAverages() {
        #expect(UsageFormatting.pickups(12, perDay: false) == "12 pickups")
        #expect(UsageFormatting.pickups(12, perDay: true) == "12 pickups/day")
        #expect(UsageFormatting.pickups(1, perDay: true) == "1 pickup/day")
    }

    @Test func headlineNamesTheMeasure() {
        #expect(UsageFormatting.headline(perDay: false) == "Total Screen Time")
        #expect(UsageFormatting.headline(perDay: true) == "Daily Average")
    }

    @Test func emptyStateNamesThePeriod() {
        #expect(UsageFormatting.emptyTitle(for: .day) == "No usage recorded for this day")
        #expect(UsageFormatting.emptyTitle(for: .week(daysCounted: 7)) == "No usage recorded for this week")
    }
}

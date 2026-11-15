import Testing
import Foundation
import DeviceActivity
@testable import Nudge

// MARK: - Helpers

/// "session.timeout" builds the session pseudo-goal; anything else builds a daily
/// total goal with a stable id derived from the name.
private func goal(_ eventName: String, _ limitSeconds: Int, label: String = "X") -> GoalSummary {
    if eventName == "session.timeout" {
        return MonitoringPlan.sessionTimeoutSummary(minutes: limitSeconds / 60)
    }
    let id = eventName.unicodeScalars.reduce(1) { ($0 * 31 + Int($1.value)) % 100_000 }
    return GoalSummary(
        goalId: id,
        eventName: MonitoringPlan.goalEventBase(goalId: id),
        limitSeconds: limitSeconds,
        targetLabel: label,
        targetType: .total
    )
}

private let anyDay = utc(2026, 9, 7, 12, 0)
private let utcCal = calendar("UTC")

private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
}

private func calendar(_ tz: String) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: tz)!
    return cal
}

// MARK: - composeSummaries

@Suite("MonitoringPlan.composeSummaries")
@MainActor
struct MonitoringPlanComposeTests {

    @Test func appendsSessionTimeoutWhenConfigured() {
        let composed = MonitoringPlan.composeSummaries(
            goals: [goal("total", 7200)],
            sessionTimeoutMinutes: 45,
            today: anyDay, calendar: utcCal
        )
        #expect(composed.count == 2)
        let session = composed.first { $0.eventName == "session.timeout" }
        #expect(session?.limitSeconds == 45 * 60)
        #expect(session?.goalId == 0)
    }

    @Test func omitsSessionTimeoutWhenNil() {
        let composed = MonitoringPlan.composeSummaries(goals: [goal("total", 7200)], sessionTimeoutMinutes: nil, today: anyDay, calendar: utcCal)
        #expect(composed.map(\.eventName) == [goal("total", 7200).eventName])
    }

    @Test func omitsSessionTimeoutWhenZero() {
        let composed = MonitoringPlan.composeSummaries(goals: [goal("total", 7200)], sessionTimeoutMinutes: 0, today: anyDay, calendar: utcCal)
        #expect(composed.map(\.eventName) == [goal("total", 7200).eventName])
    }

    @Test func sessionTimeoutOnlyIsValid() {
        let composed = MonitoringPlan.composeSummaries(goals: [], sessionTimeoutMinutes: 30, today: anyDay, calendar: utcCal)
        #expect(composed.map(\.eventName) == ["session.timeout"])
    }
}

// MARK: - dayStamp

@Suite("MonitoringPlan.dayStamp")
@MainActor
struct MonitoringPlanDayStampTests {

    @Test func formatsAsISODate() {
        let stamp = MonitoringPlan.dayStamp(for: utc(2026, 9, 7, 12, 0), calendar: calendar("UTC"))
        #expect(stamp == "2026-09-07")
    }

    @Test func padsSingleDigitMonthAndDay() {
        let stamp = MonitoringPlan.dayStamp(for: utc(2026, 1, 3, 12, 0), calendar: calendar("UTC"))
        #expect(stamp == "2026-01-03")
    }

    /// The core of the bug: two instants either side of local midnight must not
    /// produce the same stamp, or monitoring never re-arms for the new day.
    @Test func changesAcrossLocalMidnight() {
        let cal = calendar("America/Denver")
        let before = MonitoringPlan.dayStamp(for: utc(2026, 9, 7, 5, 30), calendar: cal)  // 23:30 MDT Sep 6
        let after  = MonitoringPlan.dayStamp(for: utc(2026, 9, 7, 6, 30), calendar: cal)  // 00:30 MDT Sep 7
        #expect(before == "2026-09-06")
        #expect(after == "2026-09-07")
        #expect(before != after)
    }

    @Test func respectsCalendarTimeZone() {
        let instant = utc(2026, 9, 7, 5, 30)
        let denver = MonitoringPlan.dayStamp(for: instant, calendar: calendar("America/Denver"))
        let utcStamp = MonitoringPlan.dayStamp(for: instant, calendar: calendar("UTC"))
        #expect(denver == "2026-09-06")
        #expect(utcStamp == "2026-09-07")
    }
}

// MARK: - signature

@Suite("MonitoringPlan.signature")
@MainActor
struct MonitoringPlanSignatureTests {

    @Test func isOrderIndependent() {
        let a = MonitoringPlan.signature(for: [goal("total", 7200), goal("session.timeout", 2700)])
        let b = MonitoringPlan.signature(for: [goal("session.timeout", 2700), goal("total", 7200)])
        #expect(a == b, "goal fetch order must not cause a spurious re-registration")
    }

    @Test func changesWhenLimitChanges() {
        let a = MonitoringPlan.signature(for: [goal("total", 7200)])
        let b = MonitoringPlan.signature(for: [goal("total", 3600)])
        #expect(a != b)
    }

    @Test func changesWhenGoalAdded() {
        let a = MonitoringPlan.signature(for: [goal("total", 7200)])
        let b = MonitoringPlan.signature(for: [goal("total", 7200), goal("session.timeout", 2700)])
        #expect(a != b)
    }

    @Test func emptyIsStable() {
        #expect(MonitoringPlan.signature(for: []) == MonitoringPlan.signature(for: []))
    }
}

// MARK: - events

@Suite("MonitoringPlan.events")
@MainActor
struct MonitoringPlanEventTests {

    @Test func buildsMilestonesForTotalAndOneEventForSessionTimeout() {
        let total = goal("total", 7200)
        let events = MonitoringPlan.events(for: [total, goal("session.timeout", 2700)])
        #expect(events.count == 11)
        #expect(events[DeviceActivityEvent.Name("\(total.eventName).p100")] != nil)
        #expect(events[DeviceActivityEvent.Name("session.timeout")] != nil)
    }

    /// App and category goals need tokens from FamilyActivityPicker (ADR-042); without a
    /// decodable selection they are skipped rather than silently monitoring all usage.
    @Test func skipsAppAndCategoryGoalsWithoutSelection() {
        let events = MonitoringPlan.events(for: [
            GoalSummary(goalId: 2, eventName: "goal.2", limitSeconds: 1800, targetLabel: "Instagram", targetType: .app),
            GoalSummary(goalId: 3, eventName: "goal.3", limitSeconds: 3600, targetLabel: "Social", targetType: .category)
        ])
        #expect(events.isEmpty)
    }

    @Test func emptySummariesProduceNoEvents() {
        #expect(MonitoringPlan.events(for: []).isEmpty)
    }
}

// MARK: - shouldRegister

@Suite("MonitoringPlan.shouldRegister")
@MainActor
struct MonitoringPlanShouldRegisterTests {

    @Test func registersWhenMonitoringLapsed() {
        #expect(MonitoringPlan.shouldRegister(
            isMonitoringActive: false, lastDay: "2026-09-07", lastSignature: "sig",
            today: "2026-09-07", signature: "sig"
        ))
    }

    /// The reported bug: monitoring is still "active" from yesterday, but its
    /// thresholds are spent. A new calendar day must force a fresh registration.
    @Test func registersOnNewCalendarDay() {
        #expect(MonitoringPlan.shouldRegister(
            isMonitoringActive: true, lastDay: "2026-09-06", lastSignature: "sig",
            today: "2026-09-07", signature: "sig"
        ))
    }

    @Test func registersWhenGoalsChanged() {
        #expect(MonitoringPlan.shouldRegister(
            isMonitoringActive: true, lastDay: "2026-09-07", lastSignature: "old",
            today: "2026-09-07", signature: "new"
        ))
    }

    @Test func registersWhenNoPriorStamp() {
        #expect(MonitoringPlan.shouldRegister(
            isMonitoringActive: true, lastDay: nil, lastSignature: nil,
            today: "2026-09-07", signature: "sig"
        ))
    }

    /// Must be false, or the extension's intervalDidStart re-registration would
    /// re-trigger itself in a loop.
    @Test func skipsWhenAlreadyRegisteredTodayWithSameGoals() {
        #expect(!MonitoringPlan.shouldRegister(
            isMonitoringActive: true, lastDay: "2026-09-07", lastSignature: "sig",
            today: "2026-09-07", signature: "sig"
        ))
    }
}

// MARK: - register (stamping + failure handling)

@Suite("MonitoringPlan.register")
@MainActor
struct MonitoringPlanRegisterTests {

    private struct Boom: Error {}

    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "test.monitoringplan.\(name)")!
        defaults.removePersistentDomain(forName: "test.monitoringplan.\(name)")
        return defaults
    }

    private let summaries = [
        GoalSummary(goalId: 1, eventName: "goal.1", limitSeconds: 7200, targetLabel: "All Apps", targetType: .total),
        MonitoringPlan.sessionTimeoutSummary(minutes: 45)
    ]

    /// The recursion guard: restarting monitoring provokes another
    /// `intervalDidStart`, and the extension re-registers from that callback. If the
    /// day stamp were written after `startMonitoring`, the nested callback would see
    /// yesterday's stamp and recurse.
    @Test func stampsDayBeforeStartMonitoringRuns() throws {
        let defaults = freshDefaults(#function)
        var stampDuringStart: String?

        _ = try MonitoringPlan.register(
            catalog: summaries,
            defaults: defaults,
            now: utc(2026, 9, 8, 12, 0),
            calendar: calendar("UTC")
        ) { _, _ in
            stampDuringStart = defaults.string(forKey: AppGroupKeys.lastRegisteredDay)
        }

        #expect(stampDuringStart == "2026-09-08",
                "stamp must already be visible to a re-entrant intervalDidStart")
    }

    @Test func writesGoalsAndSignatureOnSuccess() throws {
        let defaults = freshDefaults(#function)

        let count = try MonitoringPlan.register(
            catalog: summaries,
            defaults: defaults,
            now: utc(2026, 9, 8, 12, 0),
            calendar: calendar("UTC")
        ) { _, _ in }

        #expect(count == 11, "10 milestones for the total goal + session.timeout")
        #expect(defaults.string(forKey: AppGroupKeys.lastRegisteredSignature)
                == MonitoringPlan.signature(for: summaries))
        #expect(MonitoringPlan.loadSummaries(from: defaults).map(\.eventName).sorted()
                == ["goal.1", "session.timeout"])
    }

    /// A failed registration must not leave a stamp claiming success, or the next
    /// re-arm opportunity would skip and monitoring would stay dead all day.
    @Test func restoresPreviousStampsWhenStartMonitoringThrows() throws {
        let defaults = freshDefaults(#function)
        defaults.set("2026-09-07", forKey: AppGroupKeys.lastRegisteredDay)
        defaults.set("old-signature", forKey: AppGroupKeys.lastRegisteredSignature)

        #expect(throws: Boom.self) {
            _ = try MonitoringPlan.register(
                catalog: summaries,
                defaults: defaults,
                now: utc(2026, 9, 8, 12, 0),
                calendar: calendar("UTC")
            ) { _, _ in throw Boom() }
        }

        #expect(defaults.string(forKey: AppGroupKeys.lastRegisteredDay) == "2026-09-07")
        #expect(defaults.string(forKey: AppGroupKeys.lastRegisteredSignature) == "old-signature")
    }

    @Test func clearsStampsWhenFailingWithNoPreviousRegistration() throws {
        let defaults = freshDefaults(#function)

        #expect(throws: Boom.self) {
            _ = try MonitoringPlan.register(
                catalog: summaries,
                defaults: defaults,
                now: utc(2026, 9, 8, 12, 0),
                calendar: calendar("UTC")
            ) { _, _ in throw Boom() }
        }

        #expect(defaults.string(forKey: AppGroupKeys.lastRegisteredDay) == nil)
        #expect(defaults.string(forKey: AppGroupKeys.lastRegisteredSignature) == nil)
    }

    /// Full day-rollover sequence: register, roll the clock forward, and confirm the
    /// second day re-registers rather than staying silent.
    @Test func reregistersAfterDayRollover() throws {
        let defaults = freshDefaults(#function)
        let cal = calendar("UTC")
        var starts = 0

        _ = try MonitoringPlan.register(
            catalog: summaries, defaults: defaults,
            now: utc(2026, 9, 7, 9, 0), calendar: cal
        ) { _, _ in starts += 1 }

        let sig = MonitoringPlan.signature(for: summaries)

        #expect(!MonitoringPlan.shouldRegister(
            isMonitoringActive: true,
            lastDay: defaults.string(forKey: AppGroupKeys.lastRegisteredDay),
            lastSignature: defaults.string(forKey: AppGroupKeys.lastRegisteredSignature),
            today: MonitoringPlan.dayStamp(for: utc(2026, 9, 7, 21, 0), calendar: cal),
            signature: sig
        ), "same day must not re-register")

        #expect(MonitoringPlan.shouldRegister(
            isMonitoringActive: true,
            lastDay: defaults.string(forKey: AppGroupKeys.lastRegisteredDay),
            lastSignature: defaults.string(forKey: AppGroupKeys.lastRegisteredSignature),
            today: MonitoringPlan.dayStamp(for: utc(2026, 9, 8, 0, 1), calendar: cal),
            signature: sig
        ), "new day must re-arm the spent thresholds")

        #expect(starts == 1)
    }
}

// MARK: - isRegistrationStale (extension loop guard)

@Suite("MonitoringPlan.isRegistrationStale")
@MainActor
struct MonitoringPlanStaleTests {

    @Test func staleOnNewDay() {
        #expect(MonitoringPlan.isRegistrationStale(
            lastDay: "2026-09-06", lastSignature: "sig", today: "2026-09-07", signature: "sig"))
    }

    @Test func staleOnChangedGoals() {
        #expect(MonitoringPlan.isRegistrationStale(
            lastDay: "2026-09-07", lastSignature: "old", today: "2026-09-07", signature: "new"))
    }

    @Test func staleWhenNeverRegistered() {
        #expect(MonitoringPlan.isRegistrationStale(
            lastDay: nil, lastSignature: nil, today: "2026-09-07", signature: "sig"))
    }

    /// The property that bounds the extension's re-registration: once `register`
    /// has stamped today, a second pass over the same state must be a no-op, so
    /// intervalDidStart → register → intervalDidStart terminates.
    @Test func freshAfterRegisteringToday() {
        #expect(!MonitoringPlan.isRegistrationStale(
            lastDay: "2026-09-07", lastSignature: "sig", today: "2026-09-07", signature: "sig"))
    }

    /// Unlike the app-side check, this one ignores whether the center reports any
    /// active activities — an unreliable reading there would re-register forever.
    @Test func ignoresMonitoringActiveState() {
        let stale = MonitoringPlan.isRegistrationStale(
            lastDay: "2026-09-07", lastSignature: "sig", today: "2026-09-07", signature: "sig")
        let appSide = MonitoringPlan.shouldRegister(
            isMonitoringActive: false,
            lastDay: "2026-09-07", lastSignature: "sig", today: "2026-09-07", signature: "sig")
        #expect(!stale)
        #expect(appSide, "the app still recovers a lapsed registration after a restart")
    }
}

import Testing
import Foundation
import DeviceActivity
@testable import Nudge

// Phase 5E-2 — daily report (total-only, approximate).
// See docs/specs/phase-5e-trigger-settings.md → "Daily report".

// MARK: - Helpers

private func utcDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, _ s: Int = 0) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min; c.second = s
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
}

private func fixedCalendar(_ tz: String) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: tz)!
    return cal
}

private let utcCal = fixedCalendar("UTC")

private func freshDefaults(_ name: String) -> UserDefaults {
    let suite = "test.dailyreport.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private func settings(report: Bool, hour: Int = 8, minute: Int = 0) -> NudgeTriggerSettings {
    NudgeTriggerSettings(
        goalBreachEnabled: false,
        dailyReportEnabled: report,
        dailyReportTime: TimeOfDay(hour: hour, minute: minute)
    )
}

private func totalGoal(id: Int, limit: Int = 7200) -> GoalSummary {
    GoalSummary(
        goalId: id,
        eventName: MonitoringPlan.goalEventBase(goalId: id),
        limitSeconds: limit,
        targetLabel: "All Apps",
        targetType: .total
    )
}

private func trigger(
    _ name: String,
    report: String = "r",
    timestamp: Date = utcDate(2026, 11, 14, 0, 0),
    notBefore: Date? = nil
) -> PendingTrigger {
    PendingTrigger(eventName: name, report: report, timestamp: timestamp, notBefore: notBefore)
}

// MARK: - Event naming / thresholds / parsing

@Suite("Daily report — total milestone events")
@MainActor
struct DailyTotalEventTests {

    @Test func stepsAreEvery15MinutesUpTo12Hours() {
        let minutes = MonitoringPlan.dailyTotalMilestoneMinutes
        #expect(MonitoringPlan.dailyTotalStepMinutes == 15)
        #expect(MonitoringPlan.dailyTotalMaxMinutes == 720)
        #expect(minutes.count == 48)
        #expect(minutes.first == 15)
        #expect(minutes.last == 720)
        #expect(zip(minutes, minutes.dropFirst()).allSatisfy { $1 - $0 == 15 })
    }

    @Test func eventNameFormatHasNoPadding() {
        #expect(MonitoringPlan.dailyTotalEventName(minutes: 15) == "total.m15")
        #expect(MonitoringPlan.dailyTotalEventName(minutes: 90) == "total.m90")
        #expect(MonitoringPlan.dailyTotalEventName(minutes: 720) == "total.m720")
    }

    @Test func specsAreMinutesInSeconds() {
        let specs = MonitoringPlan.dailyTotalEventSpecs
        #expect(specs.count == 48)
        #expect(specs.first == MonitoringPlan.EventSpec(name: "total.m15", thresholdSeconds: 900))
        #expect(specs.last == MonitoringPlan.EventSpec(name: "total.m720", thresholdSeconds: 43_200))
    }

    @Test func parsesEveryRegisteredName() {
        for minutes in MonitoringPlan.dailyTotalMilestoneMinutes {
            let name = MonitoringPlan.dailyTotalEventName(minutes: minutes)
            #expect(MonitoringPlan.parseEventName(name) == .dailyTotal(minutes: minutes))
        }
    }

    @Test func rejectsNonCanonicalAndOutOfRangeNames() {
        for name in [
            "total", "total.", "total.m", "total.m0", "total.m14", "total.m16", "total.m735",
            "total.m015", "total.m+15", "total.m-15", "total.m 15", "total.15", "total.m15.x",
            "total.M15", "Total.m15", "xtotal.m15", "total.m15 ",
        ] {
            #expect(MonitoringPlan.parseEventName(name) == .unknown, "\(name) must not parse")
        }
    }

    @Test func goalAndSessionNamesStillParse() {
        #expect(MonitoringPlan.parseEventName("goal.4.p50") == .milestone(goalId: 4, percent: 50))
        #expect(MonitoringPlan.parseEventName("session.timeout") == .sessionTimeout)
    }
}

// MARK: - Registration: events, signature, re-arm

@Suite("Daily report — registration")
@MainActor
struct DailyReportRegistrationTests {

    private let catalog = [totalGoal(id: 1), MonitoringPlan.sessionTimeoutSummary(minutes: 45)]

    @Test func reportEnabledAdds48UnfilteredTotalEvents() {
        let events = MonitoringPlan.registrationEvents(for: catalog, dailyReportEnabled: true)
        #expect(events.count == 10 + 1 + 48)
        let total = events[DeviceActivityEvent.Name("total.m60")]
        #expect(total != nil)
        #expect(total?.applications.isEmpty == true)
        #expect(total?.categories.isEmpty == true)
        #expect(total?.webDomains.isEmpty == true)
        #expect(total?.threshold == DateComponents(hour: 1, minute: 0, second: 0))
        #expect(events[DeviceActivityEvent.Name("total.m720")]?.threshold == DateComponents(hour: 12, minute: 0, second: 0))
    }

    @Test func reportDisabledAddsNoTotalEvents() {
        let events = MonitoringPlan.registrationEvents(for: catalog, dailyReportEnabled: false)
        #expect(events.count == 11)
        #expect(!events.keys.contains { $0.rawValue.hasPrefix("total.m") })
    }

    @Test func reportOnlyWithNoGoalsIs48Events() {
        #expect(MonitoringPlan.registrationEvents(for: [], dailyReportEnabled: true).count == 48)
    }

    @Test func signatureChangesWhenReportToggled() {
        #expect(MonitoringPlan.registrationSignature(for: catalog, dailyReportEnabled: true)
                != MonitoringPlan.registrationSignature(for: catalog, dailyReportEnabled: false))
    }

    /// Upgraded installs with the report off must not re-register (and reset the day's
    /// counters) just because the signature format grew.
    @Test func signatureWithReportOffIsUnchangedFromGoalsOnly() {
        #expect(MonitoringPlan.registrationSignature(for: catalog, dailyReportEnabled: false)
                == MonitoringPlan.signature(for: catalog))
    }

    @Test func signatureFromAppGroupIgnoresReportTime() {
        let a = freshDefaults(#function + "a")
        let b = freshDefaults(#function + "b")
        NudgeTriggerSettings.persist(settings(report: true, hour: 8), defaults: a)
        NudgeTriggerSettings.persist(settings(report: true, hour: 21, minute: 30), defaults: b)
        let now = utcDate(2026, 11, 14)
        #expect(MonitoringPlan.registrationSignature(catalog: catalog, defaults: a, now: now, calendar: utcCal)
                == MonitoringPlan.registrationSignature(catalog: catalog, defaults: b, now: now, calendar: utcCal))
    }

    @Test func signatureFromAppGroupFollowsToggle() {
        let on = freshDefaults(#function + "on")
        let off = freshDefaults(#function + "off")
        let missing = freshDefaults(#function + "missing")
        NudgeTriggerSettings.persist(settings(report: true), defaults: on)
        NudgeTriggerSettings.persist(settings(report: false), defaults: off)
        let now = utcDate(2026, 11, 14)
        let sigOn = MonitoringPlan.registrationSignature(catalog: catalog, defaults: on, now: now, calendar: utcCal)
        let sigOff = MonitoringPlan.registrationSignature(catalog: catalog, defaults: off, now: now, calendar: utcCal)
        let sigMissing = MonitoringPlan.registrationSignature(catalog: catalog, defaults: missing, now: now, calendar: utcCal)
        #expect(sigOn != sigOff)
        #expect(sigMissing == sigOff, "missing settings fail closed (report off)")
    }

    @Test func registerReadsReportToggleFromAppGroup() throws {
        let defaults = freshDefaults(#function)
        NudgeTriggerSettings.persist(settings(report: true), defaults: defaults)
        var registered: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]

        let count = try MonitoringPlan.register(
            catalog: catalog, defaults: defaults, now: utcDate(2026, 11, 14), calendar: utcCal
        ) { _, events in registered = events }

        #expect(count == 59)
        #expect(registered.keys.contains(DeviceActivityEvent.Name("total.m15")))
        #expect(defaults.string(forKey: AppGroupKeys.lastRegisteredSignature)
                == MonitoringPlan.registrationSignature(for: catalog, dailyReportEnabled: true))
    }

    @Test func extensionReArmRegistersReportEventsWithEmptyCatalog() {
        let defaults = freshDefaults(#function)
        NudgeTriggerSettings.persist(settings(report: true), defaults: defaults)
        var registered: [DeviceActivityEvent.Name: DeviceActivityEvent]?

        let did = MonitoringPlan.reregisterFromAppGroupIfNeeded(
            defaults: defaults, now: utcDate(2026, 11, 14), calendar: utcCal
        ) { _, events in registered = events }

        #expect(did)
        #expect(registered?.count == 48)
    }

    @Test func extensionReArmSkipsEmptyCatalogWithReportOff() {
        let defaults = freshDefaults(#function)
        NudgeTriggerSettings.persist(settings(report: false), defaults: defaults)
        var calls = 0
        let did = MonitoringPlan.reregisterFromAppGroupIfNeeded(
            defaults: defaults, now: utcDate(2026, 11, 14), calendar: utcCal
        ) { _, _ in calls += 1 }
        #expect(!did)
        #expect(calls == 0)
    }

    @Test func togglingReportMakesRegistrationStaleButTimeChangeDoesNot() throws {
        let defaults = freshDefaults(#function)
        let now = utcDate(2026, 11, 14, 9)
        NudgeTriggerSettings.persist(settings(report: false), defaults: defaults)
        try MonitoringPlan.register(catalog: catalog, defaults: defaults, now: now, calendar: utcCal) { _, _ in }

        var calls = 0
        let reArm = { MonitoringPlan.reregisterFromAppGroupIfNeeded(defaults: defaults, now: now, calendar: utcCal) { _, _ in calls += 1 } }

        #expect(!reArm(), "same day, same settings → no re-registration")

        NudgeTriggerSettings.persist(settings(report: true), defaults: defaults)
        #expect(reArm(), "turning the report on re-registers")
        #expect(calls == 1)

        NudgeTriggerSettings.persist(settings(report: true, hour: 22), defaults: defaults)
        #expect(!reArm(), "changing only the time does not re-register")
        #expect(calls == 1)

        NudgeTriggerSettings.persist(settings(report: false), defaults: defaults)
        #expect(reArm(), "turning the report off re-registers")
        #expect(calls == 2)
    }

    /// The re-registration provoked by the extension's own `startMonitoring` is the
    /// loop risk (ADR-054): the second pass must be a no-op with the report on too.
    @Test func secondReArmOnSameDayIsNoOp() {
        let defaults = freshDefaults(#function)
        NudgeTriggerSettings.persist(settings(report: true), defaults: defaults)
        MonitoringPlan.persistCatalog(catalog, defaults: defaults)
        var calls = 0
        let now = utcDate(2026, 11, 14, 0, 0, 5)
        #expect(MonitoringPlan.reregisterFromAppGroupIfNeeded(defaults: defaults, now: now, calendar: utcCal) { _, _ in calls += 1 })
        #expect(!MonitoringPlan.reregisterFromAppGroupIfNeeded(defaults: defaults, now: now, calendar: utcCal) { _, _ in calls += 1 })
        #expect(calls == 1)
    }
}

// MARK: - dailyTotal recording + prune

@Suite("Daily report — dailyTotal recording")
@MainActor
struct DailyTotalRecordingTests {

    private let day = "2026-11-14"

    @Test func keyFormats() {
        #expect(AppGroupKeys.dailyTotalKey(day: "2026-11-14") == "nudge.dailyTotal.2026-11-14")
        #expect(AppGroupKeys.dailyReportEnqueuedKey(day: "2026-11-14") == "nudge.dailyReport.enqueued.2026-11-14")
    }

    @Test func unrecordedDayIsNil() {
        #expect(GoalProgressStore(defaults: freshDefaults(#function)).dailyTotalMinutes(onDay: day) == nil)
    }

    @Test func recordingKeepsTheMaximum() {
        let store = GoalProgressStore(defaults: freshDefaults(#function))
        store.recordDailyTotal(minutes: 30, day: day)
        #expect(store.dailyTotalMinutes(onDay: day) == 30)
        store.recordDailyTotal(minutes: 15, day: day)
        #expect(store.dailyTotalMinutes(onDay: day) == 30, "a re-fired lower milestone must not lower the total")
        store.recordDailyTotal(minutes: 45, day: day)
        #expect(store.dailyTotalMinutes(onDay: day) == 45)
        #expect(store.dailyTotalMinutes(onDay: "2026-11-15") == nil, "day-scoped")
    }

    @Test func routerRecordsTotalMilestoneWithoutCatalog() {
        let store = GoalProgressStore(defaults: freshDefaults(#function))
        let outcome = ThresholdRouter.route(eventName: "total.m45", catalog: [], store: store, day: day)
        #expect(outcome == .dailyTotal(minutes: 45))
        #expect(store.dailyTotalMinutes(onDay: day) == 45)
    }

    @Test func routerMaxMergesRepeatedAndLowerMilestones() {
        let store = GoalProgressStore(defaults: freshDefaults(#function))
        _ = ThresholdRouter.route(eventName: "total.m90", catalog: [], store: store, day: day)
        _ = ThresholdRouter.route(eventName: "total.m15", catalog: [], store: store, day: day)
        _ = ThresholdRouter.route(eventName: "total.m90", catalog: [], store: store, day: day)
        #expect(store.dailyTotalMinutes(onDay: day) == 90)
        #expect(store.progress(onDay: day).isEmpty, "total milestones are not goal progress")
    }

    @Test func pruneKeepsYesterdayAndRemovesOlderDays() {
        let defaults = freshDefaults(#function)
        let store = GoalProgressStore(defaults: defaults)
        for d in ["2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13", "2026-11-14"] {
            store.recordDailyTotal(minutes: 60, day: d)
            store.markDailyReportEnqueued(forDay: d)
        }
        defaults.set(5, forKey: "nudge.dailyTotal.garbage")

        store.prune(keepingDaysFrom: utcDate(2026, 11, 14, 0, 0, 5), calendar: utcCal)

        #expect(store.dailyTotalMinutes(onDay: "2026-11-13") == 60, "yesterday must survive the midnight prune")
        #expect(store.dailyTotalMinutes(onDay: "2026-11-14") == 60)
        #expect(store.dailyTotalMinutes(onDay: "2026-11-12") == 60)
        #expect(store.dailyTotalMinutes(onDay: "2026-11-11") == nil)
        #expect(store.dailyTotalMinutes(onDay: "2026-11-10") == nil)
        #expect(store.isDailyReportEnqueued(forDay: "2026-11-13"))
        #expect(!store.isDailyReportEnqueued(forDay: "2026-11-11"))
        #expect(defaults.object(forKey: "nudge.dailyTotal.garbage") == nil)
    }

    @Test func markEnqueuedIsTestAndSet() {
        let store = GoalProgressStore(defaults: freshDefaults(#function))
        #expect(!store.isDailyReportEnqueued(forDay: day))
        #expect(store.markDailyReportEnqueued(forDay: day) == true)
        #expect(store.markDailyReportEnqueued(forDay: day) == false)
        #expect(store.isDailyReportEnqueued(forDay: day))
    }
}

// MARK: - Midnight enqueue

@Suite("Daily report — midnight enqueue")
@MainActor
struct DailyReportEnqueueTests {

    /// 00:00:05 on 2026-11-14 UTC: yesterday is 2026-11-13.
    private let midnight = utcDate(2026, 11, 14, 0, 0, 5)

    private func prepared(_ name: String, report: Bool = true, recorded: Int? = 195) -> UserDefaults {
        let defaults = freshDefaults(name)
        NudgeTriggerSettings.persist(settings(report: report, hour: 8), defaults: defaults)
        defaults.set("Josh", forKey: AppGroupKeys.userFirstName)
        if let recorded {
            GoalProgressStore(defaults: defaults).recordDailyTotal(minutes: recorded, day: "2026-11-13")
        }
        return defaults
    }

    @Test func enqueuesYesterdaysReportForTodayAtReportTime() throws {
        let defaults = prepared(#function)

        let enqueued = try #require(DailyReport.enqueueIfNeeded(defaults: defaults, now: midnight, calendar: utcCal))

        #expect(enqueued.eventName == "daily.report")
        #expect(enqueued.eventName == DailyReport.triggerEventName)
        #expect(enqueued.report == "Josh's screen time yesterday: about 3h 15m.")
        #expect(enqueued.notBefore == utcDate(2026, 11, 14, 8, 0))
        #expect(enqueued.timestamp == midnight)
        let queue = PendingTriggerQueue.load(from: defaults)
        #expect(queue.count == 1)
        #expect(queue.first?.notBefore == utcDate(2026, 11, 14, 8, 0))
        #expect(GoalProgressStore(defaults: defaults).isDailyReportEnqueued(forDay: "2026-11-13"))
    }

    @Test func disabledReportEnqueuesNothing() {
        let defaults = prepared(#function, report: false)
        #expect(DailyReport.enqueueIfNeeded(defaults: defaults, now: midnight, calendar: utcCal) == nil)
        #expect(PendingTriggerQueue.load(from: defaults).isEmpty)
        #expect(!GoalProgressStore(defaults: defaults).isDailyReportEnqueued(forDay: "2026-11-13"))
    }

    @Test func missingSettingsEnqueueNothing() {
        let defaults = freshDefaults(#function)
        GoalProgressStore(defaults: defaults).recordDailyTotal(minutes: 60, day: "2026-11-13")
        #expect(DailyReport.enqueueIfNeeded(defaults: defaults, now: midnight, calendar: utcCal) == nil)
    }

    @Test func nothingRecordedForYesterdayEnqueuesNothing() {
        let defaults = prepared(#function, recorded: nil)
        GoalProgressStore(defaults: defaults).recordDailyTotal(minutes: 60, day: "2026-11-14")
        #expect(DailyReport.enqueueIfNeeded(defaults: defaults, now: midnight, calendar: utcCal) == nil,
                "only yesterday's value counts, never today's")
        #expect(PendingTriggerQueue.load(from: defaults).isEmpty)
    }

    @Test func alreadyEnqueuedEnqueuesNothing() {
        let defaults = prepared(#function)
        GoalProgressStore(defaults: defaults).markDailyReportEnqueued(forDay: "2026-11-13")
        #expect(DailyReport.enqueueIfNeeded(defaults: defaults, now: midnight, calendar: utcCal) == nil)
        #expect(PendingTriggerQueue.load(from: defaults).isEmpty)
    }

    /// Re-registering from `intervalDidStart` provokes a second `intervalDidStart`
    /// (ADR-054). The second pass must not enqueue a second report.
    @Test func secondIntervalDidStartIsNoOp() {
        let defaults = prepared(#function)
        #expect(DailyReport.enqueueIfNeeded(defaults: defaults, now: midnight, calendar: utcCal) != nil)
        #expect(DailyReport.enqueueIfNeeded(defaults: defaults, now: midnight.addingTimeInterval(2), calendar: utcCal) == nil)
        #expect(PendingTriggerQueue.load(from: defaults).count == 1)
    }

    @Test func appendsWithoutDisturbingQueuedTriggers() {
        let defaults = prepared(#function)
        let existing = trigger("goal.1.p100", report: "breach")
        PendingTriggerQueue.append(existing, to: defaults)

        _ = DailyReport.enqueueIfNeeded(defaults: defaults, now: midnight, calendar: utcCal)

        let queue = PendingTriggerQueue.load(from: defaults)
        #expect(queue.map(\.eventName) == ["goal.1.p100", "daily.report"])
        #expect(queue.first == existing)
    }

    @Test func fallsBackToGenericNameWhenFirstNameMissing() throws {
        let defaults = prepared(#function)
        defaults.removeObject(forKey: AppGroupKeys.userFirstName)
        let enqueued = try #require(DailyReport.enqueueIfNeeded(defaults: defaults, now: midnight, calendar: utcCal))
        #expect(enqueued.report == "Your friend's screen time yesterday: about 3h 15m.")
    }

    @Test func pureDecisionMatchesRules() {
        let s = settings(report: true)
        #expect(DailyReport.makeTrigger(settings: s, recordedMinutes: 60, alreadyEnqueued: false, userName: "J", now: midnight, calendar: utcCal) != nil)
        #expect(DailyReport.makeTrigger(settings: settings(report: false), recordedMinutes: 60, alreadyEnqueued: false, userName: "J", now: midnight, calendar: utcCal) == nil)
        #expect(DailyReport.makeTrigger(settings: s, recordedMinutes: nil, alreadyEnqueued: false, userName: "J", now: midnight, calendar: utcCal) == nil)
        #expect(DailyReport.makeTrigger(settings: s, recordedMinutes: 0, alreadyEnqueued: false, userName: "J", now: midnight, calendar: utcCal) == nil)
        #expect(DailyReport.makeTrigger(settings: s, recordedMinutes: 60, alreadyEnqueued: true, userName: "J", now: midnight, calendar: utcCal) == nil)
    }

    @Test func reportedDayIsYesterdayInLocalCalendar() {
        let denver = fixedCalendar("America/Denver")
        // 2026-11-14 07:00:05 UTC = 00:00:05 MST on the 14th.
        #expect(DailyReport.reportedDay(now: utcDate(2026, 11, 14, 7, 0, 5), calendar: denver) == "2026-11-13")
        // Spring forward day: midnight MST on 2026-03-08.
        #expect(DailyReport.reportedDay(now: utcDate(2026, 3, 8, 7, 0, 5), calendar: denver) == "2026-03-07")
    }
}

// MARK: - notBefore

@Suite("Daily report — notBefore")
@MainActor
struct DailyReportNotBeforeTests {

    private let denver = fixedCalendar("America/Denver")

    @Test func isTodayAtTheReportTime() {
        let now = utcDate(2026, 11, 14, 0, 0, 5)
        #expect(DailyReport.notBefore(time: TimeOfDay(hour: 8, minute: 0), now: now, calendar: utcCal) == utcDate(2026, 11, 14, 8, 0))
        #expect(DailyReport.notBefore(time: TimeOfDay(hour: 21, minute: 45), now: now, calendar: utcCal) == utcDate(2026, 11, 14, 21, 45))
    }

    @Test func springForwardMissingTimeResolvesToSameLocalDay() {
        // 2026-03-08: 02:00 MST jumps to 03:00 MDT, so 02:30 does not exist.
        let midnight = utcDate(2026, 3, 8, 7, 0, 5)
        let nb = DailyReport.notBefore(time: TimeOfDay(hour: 2, minute: 30), now: midnight, calendar: denver)
        #expect(MonitoringPlan.dayStamp(for: nb, calendar: denver) == "2026-03-08")
        #expect(nb >= utcDate(2026, 3, 8, 9, 0), "no earlier than 03:00 MDT")
        #expect(nb <= utcDate(2026, 3, 8, 9, 30))
    }

    @Test func springForwardDayUsesTheNewOffset() {
        let midnight = utcDate(2026, 3, 8, 7, 0, 5)
        // 08:00 MDT = 14:00 UTC.
        #expect(DailyReport.notBefore(time: TimeOfDay(hour: 8, minute: 0), now: midnight, calendar: denver) == utcDate(2026, 3, 8, 14, 0))
    }

    @Test func fallBackDayUsesTheNewOffset() {
        // 2026-11-01 midnight MDT = 06:00 UTC; 08:00 MST = 15:00 UTC.
        let midnight = utcDate(2026, 11, 1, 6, 0, 5)
        #expect(DailyReport.notBefore(time: TimeOfDay(hour: 8, minute: 0), now: midnight, calendar: denver) == utcDate(2026, 11, 1, 15, 0))
    }

    /// A mid-day `intervalDidStart` (provoked by an app registration after a missed
    /// midnight) with a report time already past: due immediately.
    @Test func timeEarlierThanNowIsDueImmediately() throws {
        let defaults = freshDefaults(#function)
        NudgeTriggerSettings.persist(settings(report: true, hour: 8), defaults: defaults)
        GoalProgressStore(defaults: defaults).recordDailyTotal(minutes: 60, day: "2026-11-13")
        let afternoon = utcDate(2026, 11, 14, 15, 0)

        let t = try #require(DailyReport.enqueueIfNeeded(defaults: defaults, now: afternoon, calendar: utcCal))

        #expect(t.notBefore == utcDate(2026, 11, 14, 8, 0))
        let p = PendingTriggerQueue.partition([t], now: afternoon, calendar: utcCal, dailyReportEnabled: true)
        #expect(p.due == [t])
        #expect(PendingTriggerQueue.earliestBeginDate(for: [t], now: afternoon) == nil)
    }
}

// MARK: - PendingTrigger coding

@Suite("Daily report — PendingTrigger notBefore coding")
@MainActor
struct PendingTriggerNotBeforeCodingTests {

    @Test func oldQueuedJSONStillDecodes() throws {
        let json = #"[{"event_name":"goal.1.p100","report":"r","timestamp":700000000}]"#
        let decoded = try JSONDecoder().decode([PendingTrigger].self, from: Data(json.utf8))
        #expect(decoded.count == 1)
        #expect(decoded[0].notBefore == nil)
        #expect(decoded[0].eventName == "goal.1.p100")
    }

    @Test func oldQueuedJSONInAppGroupStillLoads() {
        let defaults = freshDefaults(#function)
        defaults.set(Data(#"[{"event_name":"session.timeout","report":"r","timestamp":1}]"#.utf8),
                     forKey: AppGroupKeys.triggersPending)
        #expect(PendingTriggerQueue.load(from: defaults).map(\.eventName) == ["session.timeout"])
    }

    @Test func roundTripsNotBeforeUnderSnakeCaseKey() throws {
        let t = trigger("daily.report", notBefore: utcDate(2026, 11, 14, 8, 0))
        let data = try JSONEncoder().encode(t)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["not_before"] != nil)
        #expect(json["notBefore"] == nil)
        #expect(try JSONDecoder().decode(PendingTrigger.self, from: data) == t)
    }

    @Test func nilNotBeforeIsOmitted() throws {
        let data = try JSONEncoder().encode(trigger("goal.1.p100"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["not_before"] == nil)
    }
}

// MARK: - Queue partition + BG scheduling (pure)

@Suite("Daily report — pending queue partition")
@MainActor
struct PendingTriggerPartitionTests {

    private let now = utcDate(2026, 11, 14, 9, 0)

    @Test func nilAndPastNotBeforeAreDue() {
        let a = trigger("goal.1.p100")
        let b = trigger("daily.report", notBefore: utcDate(2026, 11, 14, 8, 0))
        let c = trigger("session.timeout", notBefore: now)
        let p = PendingTriggerQueue.partition([a, b, c], now: now, calendar: utcCal, dailyReportEnabled: true)
        #expect(p.due == [a, b, c])
        #expect(p.deferred.isEmpty)
        #expect(p.dropped.isEmpty)
    }

    @Test func futureNotBeforeIsDeferred() {
        let later = trigger("daily.report", notBefore: utcDate(2026, 11, 14, 21, 0))
        let p = PendingTriggerQueue.partition([later], now: now, calendar: utcCal, dailyReportEnabled: true)
        #expect(p.due.isEmpty)
        #expect(p.deferred == [later])
    }

    @Test func mixedQueueSplitsAndKeepsOrder() {
        let a = trigger("goal.1.p100")
        let b = trigger("daily.report", notBefore: utcDate(2026, 11, 14, 21, 0))
        let c = trigger("session.timeout")
        let p = PendingTriggerQueue.partition([a, b, c], now: now, calendar: utcCal, dailyReportEnabled: true)
        #expect(p.due == [a, c])
        #expect(p.deferred == [b])
    }

    @Test func disabledReportDropsOnlyDailyReports() {
        let a = trigger("goal.1.p100")
        let due = trigger("daily.report", notBefore: utcDate(2026, 11, 14, 8, 0))
        let later = trigger("daily.report", timestamp: utcDate(2026, 11, 14, 0, 1), notBefore: utcDate(2026, 11, 14, 21, 0))
        let p = PendingTriggerQueue.partition([a, due, later], now: now, calendar: utcCal, dailyReportEnabled: false)
        #expect(p.due == [a])
        #expect(p.deferred.isEmpty)
        #expect(p.dropped == [due, later])
    }

    /// "Yesterday" in the copy is only true on the day the report was due.
    @Test func dailyReportExpiresAtTheEndOfItsDay() {
        let stale = trigger("daily.report", notBefore: utcDate(2026, 11, 13, 8, 0))
        let lastMinute = utcDate(2026, 11, 13, 23, 59)
        let nextDay = utcDate(2026, 11, 14, 0, 0)
        #expect(PendingTriggerQueue.partition([stale], now: lastMinute, calendar: utcCal, dailyReportEnabled: true).due == [stale])
        let p = PendingTriggerQueue.partition([stale], now: nextDay, calendar: utcCal, dailyReportEnabled: true)
        #expect(p.dropped == [stale])
        #expect(p.due.isEmpty)
    }

    @Test func otherTriggersNeverExpire() {
        let old = trigger("goal.1.p100", timestamp: utcDate(2026, 11, 1), notBefore: utcDate(2026, 11, 1))
        #expect(PendingTriggerQueue.partition([old], now: now, calendar: utcCal, dailyReportEnabled: true).due == [old])
    }

    // earliestBeginDate

    @Test func earliestBeginDateIsNilForEmptyQueue() {
        #expect(PendingTriggerQueue.earliestBeginDate(for: [], now: now) == nil)
    }

    @Test func earliestBeginDateIsNilWhenSomethingIsDue() {
        let due = trigger("goal.1.p100")
        let later = trigger("daily.report", notBefore: utcDate(2026, 11, 14, 21, 0))
        #expect(PendingTriggerQueue.earliestBeginDate(for: [due, later], now: now) == nil,
                "a due trigger must not wait for a later one")
        #expect(PendingTriggerQueue.earliestBeginDate(for: [trigger("x", notBefore: now)], now: now) == nil)
    }

    @Test func earliestBeginDateIsTheEarliestFutureNotBefore() {
        let a = trigger("daily.report", notBefore: utcDate(2026, 11, 14, 21, 0))
        let b = trigger("daily.report", timestamp: utcDate(2026, 11, 14, 0, 1), notBefore: utcDate(2026, 11, 14, 10, 30))
        #expect(PendingTriggerQueue.earliestBeginDate(for: [a, b], now: now) == utcDate(2026, 11, 14, 10, 30))
    }
}

// MARK: - Drain (NudgeTriggerService)

private final class FakePendingTriggerStore: PendingTriggerStore {
    var triggers: [PendingTrigger]
    init(_ triggers: [PendingTrigger]) { self.triggers = triggers }
    func load() -> [PendingTrigger] { triggers }
    func save(_ triggers: [PendingTrigger]) { self.triggers = triggers }
}

@MainActor
private final class RecordingNudgeService: NudgeServiceProtocol {
    var errorToThrow: Error?
    private(set) var reports: [String] = []
    func sendNudge(friendId: Int, report: String) async throws {
        if let errorToThrow { throw errorToThrow }
        reports.append(report)
    }
}

@MainActor
private final class CountingFriendService: FriendServiceProtocol {
    var errorToThrow: Error?
    var friends: [Friend] = [
        Friend(id: 1, userId: UUID(), friendName: "F", friendPhoneNumber: "+18015550000",
               status: .accepted, invitationTimestamp: Date())
    ]
    private(set) var fetchCount = 0

    func fetchFriends(userId: UUID) async throws -> [Friend] {
        fetchCount += 1
        if let errorToThrow { throw errorToThrow }
        return friends
    }
    func addFriend(userId: UUID, name: String, phoneNumber: String) async throws {}
    func deleteFriend(id: Int) async throws {}
    func updateFriendName(id: Int, name: String) async throws {}
    func fetchNudgeHistory(friendId: Int) async throws -> [Nudge] { [] }
    func fetchFriendId(forNudgeId nudgeId: Int) async throws -> Int? { nil }
}

@Suite("Daily report — drain filtering")
@MainActor
struct DailyReportDrainTests {

    private let now = utcDate(2026, 11, 14, 9, 0)

    private func service(
        _ store: FakePendingTriggerStore,
        _ nudge: RecordingNudgeService,
        _ friends: CountingFriendService,
        reportEnabled: Bool = true
    ) -> NudgeTriggerService {
        NudgeTriggerService(
            store: store,
            nudgeService: nudge,
            friendService: friends,
            now: { [now] in now },
            calendar: utcCal,
            triggerSettings: { settings(report: reportEnabled) }
        )
    }

    @Test func sendsDueAndKeepsDeferredIntact() async {
        let due = trigger("goal.1.p100", report: "breach")
        let later = trigger("daily.report", report: "report", notBefore: utcDate(2026, 11, 14, 21, 0))
        let store = FakePendingTriggerStore([due, later])
        let nudge = RecordingNudgeService()

        await service(store, nudge, CountingFriendService()).drainPendingTriggers(userId: UUID())

        #expect(nudge.reports == ["breach"])
        #expect(store.triggers == [later])
    }

    @Test func sendsDailyReportOnceDue() async {
        let report = trigger("daily.report", report: "Josh's screen time yesterday: about 1h.", notBefore: utcDate(2026, 11, 14, 8, 0))
        let store = FakePendingTriggerStore([report])
        let nudge = RecordingNudgeService()

        await service(store, nudge, CountingFriendService()).drainPendingTriggers(userId: UUID())

        #expect(nudge.reports == ["Josh's screen time yesterday: about 1h."])
        #expect(store.triggers.isEmpty)
    }

    @Test func onlyDeferredMakesNoNetworkCallsAndKeepsQueue() async {
        let later = trigger("daily.report", notBefore: utcDate(2026, 11, 14, 21, 0))
        let store = FakePendingTriggerStore([later])
        let friends = CountingFriendService()
        let nudge = RecordingNudgeService()

        await service(store, nudge, friends).drainPendingTriggers(userId: UUID())

        #expect(friends.fetchCount == 0)
        #expect(nudge.reports.isEmpty)
        #expect(store.triggers == [later])
    }

    @Test func disabledReportIsDroppedWithoutSending() async {
        let breach = trigger("goal.1.p100", report: "breach")
        let report = trigger("daily.report", report: "report", notBefore: utcDate(2026, 11, 14, 8, 0))
        let store = FakePendingTriggerStore([breach, report])
        let nudge = RecordingNudgeService()

        await service(store, nudge, CountingFriendService(), reportEnabled: false).drainPendingTriggers(userId: UUID())

        #expect(nudge.reports == ["breach"])
        #expect(store.triggers.isEmpty)
    }

    @Test func disabledReportIsDroppedEvenWhenFriendFetchFails() async {
        let breach = trigger("goal.1.p100", report: "breach")
        let report = trigger("daily.report", report: "report", notBefore: utcDate(2026, 11, 14, 21, 0))
        let store = FakePendingTriggerStore([breach, report])
        let friends = CountingFriendService()
        friends.errorToThrow = URLError(.notConnectedToInternet)

        await service(store, RecordingNudgeService(), friends, reportEnabled: false).drainPendingTriggers(userId: UUID())

        #expect(store.triggers == [breach], "due trigger retained for retry; disabled report gone")
    }

    @Test func sendFailureRetainsDueAndDeferred() async {
        let due = trigger("daily.report", report: "a", notBefore: utcDate(2026, 11, 14, 8, 0))
        let later = trigger("goal.2.p100", report: "b", timestamp: utcDate(2026, 11, 14, 1, 0), notBefore: utcDate(2026, 11, 14, 21, 0))
        let store = FakePendingTriggerStore([due, later])
        let nudge = RecordingNudgeService()
        nudge.errorToThrow = URLError(.timedOut)

        await service(store, nudge, CountingFriendService()).drainPendingTriggers(userId: UUID())

        #expect(store.triggers == [due, later])
    }

    @Test func zeroAcceptedFriendsClearsDueButKeepsDeferred() async {
        let due = trigger("goal.1.p100")
        let later = trigger("daily.report", notBefore: utcDate(2026, 11, 14, 21, 0))
        let store = FakePendingTriggerStore([due, later])
        let friends = CountingFriendService()
        friends.friends = []

        await service(store, RecordingNudgeService(), friends).drainPendingTriggers(userId: UUID())

        #expect(store.triggers == [later])
    }
}

// MARK: - Copy

@Suite("Daily report — copy")
@MainActor
struct DailyReportCopyTests {

    @Test func fifteenMinutes() {
        #expect(NudgeMessages.dailyReport(userName: "Josh", totalMinutes: 15) == "Josh's screen time yesterday: about 15m.")
    }

    @Test func hoursAndMinutes() {
        #expect(NudgeMessages.dailyReport(userName: "Josh", totalMinutes: 195) == "Josh's screen time yesterday: about 3h 15m.")
    }

    @Test func wholeHours() {
        #expect(NudgeMessages.dailyReport(userName: "Josh", totalMinutes: 60) == "Josh's screen time yesterday: about 1h.")
    }

    @Test func twelveHourMilestoneSaysOver12Hours() {
        #expect(NudgeMessages.dailyReport(userName: "Josh", totalMinutes: 720) == "Josh's screen time yesterday: over 12 hours.")
        #expect(NudgeMessages.dailyReport(userName: "Josh", totalMinutes: 705) == "Josh's screen time yesterday: about 11h 45m.")
    }

    /// Unreachable from the enqueue path (nothing recorded → no report), but the
    /// function stays total.
    @Test func underFifteenMinutes() {
        #expect(NudgeMessages.dailyReport(userName: "Josh", totalMinutes: 0) == "Josh's screen time yesterday: under 15 minutes.")
    }

    @Test func noEmoji() {
        let msg = NudgeMessages.dailyReport(userName: "Josh", totalMinutes: 720)
        #expect(msg.unicodeScalars.allSatisfy { !$0.properties.isEmojiPresentation })
    }
}

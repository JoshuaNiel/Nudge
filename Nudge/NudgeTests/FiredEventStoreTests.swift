import Testing
import Foundation
@testable import Nudge

// MARK: - Helpers

/// A throwaway suite per test so no test can see another's fired keys.
private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "test.firedeventstore.\(UUID().uuidString)")!
}

private func utcCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

private func utcDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d; c.hour = h
    return utcCalendar().date(from: c)!
}

// MARK: - Keys

@Suite("FiredEventStore keys")
@MainActor
struct FiredEventStoreKeyTests {

    @Test func dedupKeyIncludesEventAndThreshold() {
        #expect(FiredEventStore.dedupKey(eventName: "total", thresholdSeconds: 3600) == "total@3600")
        #expect(FiredEventStore.dedupKey(eventName: "session.timeout", thresholdSeconds: 2700)
                == "session.timeout@2700")
    }

    @Test func unmatchedKeyFormat() {
        #expect(FiredEventStore.unmatchedKey(eventName: "total") == "total@unmatched")
    }

    @Test func firedKeyFormat() {
        #expect(AppGroupKeys.firedKeyPrefix == "nudge.fired.")
        #expect(AppGroupKeys.firedKey(day: "2026-11-23") == "nudge.fired.2026-11-23")
    }

    @Test func retentionIsTwoDays() {
        #expect(FiredEventStore.retentionDays == 2)
    }
}

// MARK: - markFired / hasFired

@Suite("FiredEventStore.markFired")
@MainActor
struct FiredEventStoreMarkTests {

    @Test func nothingHasFiredInitially() {
        let store = FiredEventStore(defaults: isolatedDefaults())
        #expect(!store.hasFired("total@3600", onDay: "2026-11-23"))
    }

    /// The core of the dedup: only the first caller gets to run side effects.
    @Test func testAndSetReturnsTrueOnlyOnce() {
        let store = FiredEventStore(defaults: isolatedDefaults())
        #expect(store.markFired("total@3600", onDay: "2026-11-23"))
        #expect(!store.markFired("total@3600", onDay: "2026-11-23"))
        #expect(store.hasFired("total@3600", onDay: "2026-11-23"))
    }

    /// Firing yesterday must never suppress today's notification.
    @Test func daysAreIsolated() {
        let store = FiredEventStore(defaults: isolatedDefaults())
        #expect(store.markFired("total@3600", onDay: "2026-11-22"))
        #expect(!store.hasFired("total@3600", onDay: "2026-11-23"))
        #expect(store.markFired("total@3600", onDay: "2026-11-23"))
    }

    /// Raising (or lowering) a limit after it fired is a new threshold, so it must
    /// notify again at the new limit (user decision 2026-11-23).
    @Test func changedThresholdIsNotSuppressed() {
        let store = FiredEventStore(defaults: isolatedDefaults())
        let day = "2026-11-23"
        #expect(store.markFired(FiredEventStore.dedupKey(eventName: "total", thresholdSeconds: 3600), onDay: day))
        #expect(!store.hasFired(FiredEventStore.dedupKey(eventName: "total", thresholdSeconds: 7200), onDay: day))
        #expect(store.markFired(FiredEventStore.dedupKey(eventName: "total", thresholdSeconds: 7200), onDay: day))
    }

    @Test func differentEventsAreIndependent() {
        let store = FiredEventStore(defaults: isolatedDefaults())
        let day = "2026-11-23"
        #expect(store.markFired("total@3600", onDay: day))
        #expect(store.markFired("session.timeout@2700", onDay: day))
        #expect(store.hasFired("total@3600", onDay: day))
        #expect(store.hasFired("session.timeout@2700", onDay: day))
    }

    @Test func storesSortedJSONArray() throws {
        let defaults = isolatedDefaults()
        let store = FiredEventStore(defaults: defaults)
        let day = "2026-11-23"
        store.markFired("total@3600", onDay: day)
        store.markFired("session.timeout@2700", onDay: day)

        let data = try #require(defaults.data(forKey: AppGroupKeys.firedKey(day: day)))
        let decoded = try JSONDecoder().decode([String].self, from: data)
        #expect(decoded == ["session.timeout@2700", "total@3600"])
    }

    /// A corrupt value must cost at most one duplicate, never a crash or a
    /// permanently stuck key.
    @Test func unreadableDataReadsAsEmpty() {
        let defaults = isolatedDefaults()
        let day = "2026-11-23"
        defaults.set(Data("not json".utf8), forKey: AppGroupKeys.firedKey(day: day))
        let store = FiredEventStore(defaults: defaults)

        #expect(!store.hasFired("total@3600", onDay: day))
        #expect(store.markFired("total@3600", onDay: day))
        #expect(!store.markFired("total@3600", onDay: day))
    }

    @Test func wrongTypeReadsAsEmpty() {
        let defaults = isolatedDefaults()
        let day = "2026-11-23"
        defaults.set("total@3600", forKey: AppGroupKeys.firedKey(day: day))
        let store = FiredEventStore(defaults: defaults)

        #expect(!store.hasFired("total@3600", onDay: day))
        #expect(store.markFired("total@3600", onDay: day))
    }
}

// MARK: - prune

@Suite("FiredEventStore.prune")
@MainActor
struct FiredEventStorePruneTests {

    private func seed(_ defaults: UserDefaults, days: [String]) {
        let store = FiredEventStore(defaults: defaults)
        for day in days { store.markFired("total@3600", onDay: day) }
    }

    @Test func keepsTodayAndTwoPreviousDaysRemovesOlder() {
        let defaults = isolatedDefaults()
        seed(defaults, days: ["2026-11-23", "2026-11-22", "2026-11-21", "2026-11-20", "2026-10-01"])

        FiredEventStore(defaults: defaults).prune(keepingDaysFrom: utcDate(2026, 11, 23), calendar: utcCalendar())

        #expect(defaults.object(forKey: AppGroupKeys.firedKey(day: "2026-11-23")) != nil)
        #expect(defaults.object(forKey: AppGroupKeys.firedKey(day: "2026-11-22")) != nil)
        #expect(defaults.object(forKey: AppGroupKeys.firedKey(day: "2026-11-21")) != nil)
        #expect(defaults.object(forKey: AppGroupKeys.firedKey(day: "2026-11-20")) == nil)
        #expect(defaults.object(forKey: AppGroupKeys.firedKey(day: "2026-10-01")) == nil)
    }

    /// Day boundaries come from the calendar's time zone, the same as `dayStamp`.
    @Test func usesLocalDay() {
        let defaults = isolatedDefaults()
        seed(defaults, days: ["2026-11-20", "2026-11-19"])
        var denver = Calendar(identifier: .gregorian)
        denver.timeZone = TimeZone(identifier: "America/Denver")!

        // 03:00 UTC on Nov 23 is still Nov 22 in Denver → keep Nov 20, drop Nov 19.
        FiredEventStore(defaults: defaults).prune(keepingDaysFrom: utcDate(2026, 11, 23, 3), calendar: denver)

        #expect(defaults.object(forKey: AppGroupKeys.firedKey(day: "2026-11-20")) != nil)
        #expect(defaults.object(forKey: AppGroupKeys.firedKey(day: "2026-11-19")) == nil)
    }

    @Test func removesMalformedKeysUnderPrefix() {
        let defaults = isolatedDefaults()
        defaults.set(Data("[]".utf8), forKey: "nudge.fired.garbage")

        FiredEventStore(defaults: defaults).prune(keepingDaysFrom: utcDate(2026, 11, 23), calendar: utcCalendar())

        #expect(defaults.object(forKey: "nudge.fired.garbage") == nil)
    }

    @Test func leavesUnrelatedKeysAlone() {
        let defaults = isolatedDefaults()
        defaults.set("2026-01-01", forKey: AppGroupKeys.lastRegisteredDay)
        defaults.set("keep", forKey: "nudge.firedish.2026-01-01")
        seed(defaults, days: ["2026-01-01"])

        FiredEventStore(defaults: defaults).prune(keepingDaysFrom: utcDate(2026, 11, 23), calendar: utcCalendar())

        #expect(defaults.string(forKey: AppGroupKeys.lastRegisteredDay) == "2026-01-01")
        #expect(defaults.string(forKey: "nudge.firedish.2026-01-01") == "keep")
        #expect(defaults.object(forKey: AppGroupKeys.firedKey(day: "2026-01-01")) == nil)
    }
}

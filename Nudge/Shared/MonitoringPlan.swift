import Foundation
import DeviceActivity
import os

/// Single source of truth for what Nudge monitors and when it re-registers.
///
/// Compiled into **both** the `Nudge` app target and the `NudgeActivityMonitor`
/// extension target (via the `Shared/` synchronized folder). That matters: if the
/// app and the extension built their `DeviceActivityEvent` sets from separate
/// copies of this logic, a drift between them would silently disarm monitoring —
/// which is the class of bug this file exists to prevent.
///
/// **Why re-registration is needed at all (ADR-054):** a `DeviceActivityEvent`
/// threshold fires at most once per `startMonitoring` call. With a `repeats: true`
/// daily schedule, iOS does not reliably re-arm spent thresholds when the interval
/// rolls over at midnight — so without an explicit re-registration the app goes
/// silent after its first triggered day. Three independent recovery paths re-arm it
/// (extension `intervalDidStart`, extension `eventDidReachThreshold`, and app
/// foreground), all bounded by the same idempotent day stamp so none of them can loop.
enum MonitoringPlan {

    static let activityName = DeviceActivityName("nudge.daily")

    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "MonitoringPlan")

    // MARK: - Schedule

    /// The daily monitoring window. Registered even when there are no events, so
    /// `DeviceActivityReport` still has a monitored period to query (ADR-046).
    static func schedule() -> DeviceActivitySchedule {
        DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0, second: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59, second: 59),
            repeats: true
        )
    }

    // MARK: - Composition

    /// Builds the complete monitored set: the user's goals plus the session-timeout
    /// pseudo-goal. This is the only place session timeout becomes a `GoalSummary`,
    /// so the registered events and the App Group copy the extension reads can
    /// never disagree about what is being monitored.
    static func composeSummaries(goals: [GoalSummary], sessionTimeoutMinutes: Int?) -> [GoalSummary] {
        var summaries = goals
        if let minutes = sessionTimeoutMinutes, minutes > 0 {
            summaries.append(
                GoalSummary(
                    goalId: 0,
                    eventName: "session.timeout",
                    limitSeconds: minutes * 60,
                    targetLabel: "Session",
                    appBundleId: nil
                )
            )
        }
        return summaries
    }

    /// Builds the `DeviceActivityEvent` set for the given summaries — one event per
    /// summary, whose threshold is exactly `limitSeconds`. The extension relies on
    /// that 1:1 mapping to build its dedup key.
    ///
    /// App- and category-scoped goals are skipped: they need an `ApplicationToken`
    /// that only `FamilyActivityPicker` can supply (ADR-042, Phase 3).
    static func events(for summaries: [GoalSummary]) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for summary in summaries {
            guard summary.eventName == "total" || summary.eventName == "session.timeout" else { continue }
            events[DeviceActivityEvent.Name(summary.eventName)] = DeviceActivityEvent(
                applications: [],
                categories: [],
                webDomains: [],
                threshold: thresholdComponents(summary.limitSeconds),
                // Count usage since the interval started, so a mid-day
                // re-registration does not hand the user a fresh full limit.
                // The flip side — a passed threshold fires again immediately —
                // is absorbed by `FiredEventStore` in the extension (ADR-054).
                includesPastActivity: true
            )
        }
        return events
    }

    private static func thresholdComponents(_ seconds: Int) -> DateComponents {
        DateComponents(hour: seconds / 3600, minute: (seconds % 3600) / 60, second: seconds % 60)
    }

    // MARK: - Stamps

    /// Local calendar day as "yyyy-MM-dd". Computed from `DateComponents` rather
    /// than a `DateFormatter` so it is locale- and calendar-independent.
    static func dayStamp(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Order-independent fingerprint of the monitored set. Sorting matters: goal
    /// rows come back from Supabase in arbitrary order, and an order-sensitive
    /// signature would re-register (and so reset the day's counters) on every
    /// foreground.
    static func signature(for summaries: [GoalSummary]) -> String {
        summaries
            .map { "\($0.eventName)=\($0.limitSeconds)" }
            .sorted()
            .joined(separator: "|")
    }

    // MARK: - Registration decision

    /// Whether the stored registration is stale — a new calendar day (thresholds
    /// are spent) or an edited goal set.
    ///
    /// **This is the loop guard.** It depends only on the stamps `register` writes,
    /// so re-registering can happen at most once per (day, signature) no matter how
    /// many callbacks fire. The extension re-registers from `intervalDidStart`,
    /// which restarting monitoring provokes again — bounding on the stamps alone is
    /// what stops that from recursing.
    static func isRegistrationStale(
        lastDay: String?,
        lastSignature: String?,
        today: String,
        signature: String
    ) -> Bool {
        guard let lastDay, let lastSignature else { return true }
        return lastDay != today || lastSignature != signature
    }

    /// App-side check: staleness, plus recovery when monitoring lapsed entirely
    /// (device restart clears all activities).
    ///
    /// Only the main app should use this. The `isMonitoringActive` term is not
    /// self-limiting — if it were ever wrong, it would re-register on every call —
    /// so the extension, which has no way to bound its own callbacks, uses
    /// `isRegistrationStale` instead.
    static func shouldRegister(
        isMonitoringActive: Bool,
        lastDay: String?,
        lastSignature: String?,
        today: String,
        signature: String
    ) -> Bool {
        if !isMonitoringActive { return true }
        return isRegistrationStale(
            lastDay: lastDay, lastSignature: lastSignature,
            today: today, signature: signature
        )
    }

    // MARK: - App Group persistence

    /// Reads the Strategy 2 queue the extension writes and the main app drains.
    static func loadPendingTriggers(from defaults: UserDefaults?) -> [PendingTrigger] {
        guard let data = defaults?.data(forKey: AppGroupKeys.triggersPending),
              let triggers = try? JSONDecoder().decode([PendingTrigger].self, from: data) else {
            return []
        }
        return triggers
    }

    static func loadSummaries(from defaults: UserDefaults?) -> [GoalSummary] {
        guard let data = defaults?.data(forKey: AppGroupKeys.goalsActive),
              let summaries = try? JSONDecoder().decode([GoalSummary].self, from: data) else {
            return []
        }
        return summaries
    }

    // MARK: - Registration

    /// Stops and restarts monitoring for `activityName`, persists the monitored set
    /// to the App Group for the extension, and records the day/signature stamps.
    ///
    /// `summaries` must already be composed via `composeSummaries`.
    ///
    /// **Stamps are written before `startMonitoring` runs, deliberately.** Restarting
    /// monitoring while its interval is active provokes another `intervalDidStart`,
    /// and the extension re-registers from that callback — so a stamp written
    /// afterwards would let the nested callback see the stale day and recurse. On
    /// failure the previous stamps are restored so the next opportunity retries.
    ///
    /// On success it also prunes old `FiredEventStore` days.
    @discardableResult
    static func register(
        summaries: [GoalSummary],
        defaults: UserDefaults?,
        now: Date,
        calendar: Calendar,
        startMonitoring: (DeviceActivitySchedule, [DeviceActivityEvent.Name: DeviceActivityEvent]) throws -> Void
    ) throws -> Int {
        let events = events(for: summaries)
        let previousDay = defaults?.string(forKey: AppGroupKeys.lastRegisteredDay)
        let previousSignature = defaults?.string(forKey: AppGroupKeys.lastRegisteredSignature)

        defaults?.set(dayStamp(for: now, calendar: calendar), forKey: AppGroupKeys.lastRegisteredDay)
        defaults?.set(signature(for: summaries), forKey: AppGroupKeys.lastRegisteredSignature)

        do {
            try startMonitoring(schedule(), events)
        } catch {
            defaults?.setOrRemove(previousDay, forKey: AppGroupKeys.lastRegisteredDay)
            defaults?.setOrRemove(previousSignature, forKey: AppGroupKeys.lastRegisteredSignature)
            throw error
        }

        if let defaults {
            if let data = try? JSONEncoder().encode(summaries) {
                defaults.set(data, forKey: AppGroupKeys.goalsActive)
            }
            // Runs at least daily (midnight re-arm), which keeps the fired-event
            // records bounded without a dedicated cleanup job.
            FiredEventStore(defaults: defaults).prune(keepingDaysFrom: now, calendar: calendar)
        }

        logger.log("registered monitoring — \(events.count) event(s), \(summaries.count) summary(ies)")
        return events.count
    }

    /// Convenience overload driving a real `DeviceActivityCenter`.
    @discardableResult
    static func register(
        summaries: [GoalSummary],
        center: DeviceActivityCenter,
        defaults: UserDefaults?,
        now: Date,
        calendar: Calendar
    ) throws -> Int {
        try register(summaries: summaries, defaults: defaults, now: now, calendar: calendar) { schedule, events in
            center.stopMonitoring([activityName])
            try center.startMonitoring(activityName, during: schedule, events: events)
        }
    }

    /// Re-registers from the App Group copy of the monitored set, but only when
    /// `shouldRegister` says it is needed. This is the path the monitor extension
    /// uses: it runs with no main app process and no network, so the last set the
    /// app persisted is the best available source of truth.
    @discardableResult
    static func reregisterFromAppGroupIfNeeded(
        center: DeviceActivityCenter,
        defaults: UserDefaults?,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        let summaries = loadSummaries(from: defaults)
        guard !summaries.isEmpty else {
            logger.error("no goal summaries in App Group — skipping re-registration")
            return false
        }

        let today = dayStamp(for: now, calendar: calendar)
        let sig = signature(for: summaries)
        let stale = isRegistrationStale(
            lastDay: defaults?.string(forKey: AppGroupKeys.lastRegisteredDay),
            lastSignature: defaults?.string(forKey: AppGroupKeys.lastRegisteredSignature),
            today: today,
            signature: sig
        )
        guard stale else { return false }

        do {
            try register(summaries: summaries, center: center, defaults: defaults, now: now, calendar: calendar)
            return true
        } catch {
            logger.error("re-registration failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

// MARK: - UserDefaults helper

extension UserDefaults {
    /// Writes `value`, or removes the key when `value` is nil, so restoring a
    /// previously absent stamp does not leave a stale one behind.
    func setOrRemove(_ value: String?, forKey key: String) {
        if let value {
            set(value, forKey: key)
        } else {
            removeObject(forKey: key)
        }
    }
}

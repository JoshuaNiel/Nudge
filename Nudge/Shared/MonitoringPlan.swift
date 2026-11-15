import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings
import CryptoKit
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
///
/// **Catalog vs. active set (Phase 3 G6/G7):** the App Group holds the *catalog* —
/// every goal the user has, plus the session-timeout pseudo-goal — unfiltered. Each
/// registration filters it down to the goals *active today* (daily frequency, inside
/// any temporary date range). Persisting the unfiltered catalog is what lets the
/// extension arm a temporary goal on its first day, or drop an expired one, at
/// midnight with the app never opened.
///
/// **Adding weekly goals later:** weekly goals need their own `DeviceActivityName` and
/// a weekly repeating schedule. The intended shape is a second activity whose active set
/// is `activeSummaries(in:frequency: .weekly, …)`, registered alongside the daily one;
/// the catalog, naming, dedup, and signature logic are already frequency-agnostic.
enum MonitoringPlan {

    static let activityName = DeviceActivityName("nudge.daily")

    /// Apple does not document a hard cap on events per activity. Each goal costs 10
    /// events, the session timeout 1 and the daily report 48 (Phase 5E-2), so warn well
    /// before a plausible limit to make a silent failure visible.
    static let eventCountWarningThreshold = 200

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

    /// The session-timeout pseudo-goal. This is the only place session timeout becomes a
    /// `GoalSummary`, so the registered events and the App Group copy the extension reads
    /// can never disagree about it.
    static func sessionTimeoutSummary(minutes: Int) -> GoalSummary {
        GoalSummary(
            goalId: 0,
            eventName: sessionTimeoutEventName,
            limitSeconds: minutes * 60,
            targetLabel: "Session",
            targetType: .total
        )
    }

    /// The full, unfiltered monitored catalog persisted to the App Group: every goal plus
    /// the session-timeout pseudo-goal when configured.
    static func catalog(goals: [GoalSummary], sessionTimeoutMinutes: Int?) -> [GoalSummary] {
        var summaries = goals
        if let minutes = sessionTimeoutMinutes, minutes > 0 {
            summaries.append(sessionTimeoutSummary(minutes: minutes))
        }
        return summaries
    }

    /// Whether a catalog entry is monitored by the daily activity on `day` (`yyyy-MM-dd`).
    /// Day strings are zero-padded ISO dates, so string order is date order. A missing
    /// bound is open-ended; both bounds are inclusive.
    static func isActive(_ summary: GoalSummary, onDay day: String, frequency: GoalFrequency = .daily) -> Bool {
        guard summary.frequency == frequency else { return false }
        if let start = summary.startDate, day < start { return false }
        if let end = summary.endDate, day > end { return false }
        return true
    }

    /// The subset of `catalog` to register today, by the local calendar day.
    static func activeSummaries(
        in catalog: [GoalSummary],
        now: Date,
        calendar: Calendar,
        frequency: GoalFrequency = .daily
    ) -> [GoalSummary] {
        let day = dayStamp(for: now, calendar: calendar)
        return catalog.filter { isActive($0, onDay: day, frequency: frequency) }
    }

    /// Today's monitored set: the user's daily goals active today plus the session-timeout
    /// pseudo-goal.
    static func composeSummaries(
        goals: [GoalSummary],
        sessionTimeoutMinutes: Int?,
        today: Date,
        calendar: Calendar
    ) -> [GoalSummary] {
        activeSummaries(
            in: catalog(goals: goals, sessionTimeoutMinutes: sessionTimeoutMinutes),
            now: today,
            calendar: calendar
        )
    }

    // MARK: - Events

    /// Builds the `DeviceActivityEvent` set for an already-filtered active set.
    ///
    /// - Total goals and session timeout: no app filter (all usage).
    /// - App / category goals: the tokens in their decoded selection. A goal whose
    ///   selection is missing, undecodable, or empty is skipped and logged — an empty
    ///   token set would otherwise silently monitor *all* usage.
    static func events(for summaries: [GoalSummary]) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for summary in summaries {
            guard let filter = tokenFilter(for: summary) else { continue }
            for spec in eventSpecs(for: summary) {
                events[DeviceActivityEvent.Name(spec.name)] = DeviceActivityEvent(
                    applications: filter.applications,
                    categories: filter.categories,
                    webDomains: filter.webDomains,
                    threshold: thresholdComponents(spec.thresholdSeconds)
                )
            }
        }
        return events
    }

    /// The full event set for one registration: the active goals' events plus, when the
    /// daily report is on, the 48 `total.m<NN>` total-usage milestones (no app filter).
    static func registrationEvents(
        for active: [GoalSummary],
        dailyReportEnabled: Bool
    ) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        var events = events(for: active)
        if dailyReportEnabled {
            for spec in dailyTotalEventSpecs {
                // Empty token sets = all device usage, like a total goal.
                events[DeviceActivityEvent.Name(spec.name)] = DeviceActivityEvent(
                    applications: [],
                    categories: [],
                    webDomains: [],
                    threshold: thresholdComponents(spec.thresholdSeconds)
                )
            }
        }
        if events.count > eventCountWarningThreshold {
            logger.warning("registering \(events.count) events — above the \(eventCountWarningThreshold) warning threshold")
        }
        return events
    }

    /// Whether the registration should include the daily-report events. Read from the
    /// App Group by **every** registration path (app and extension), so the two can never
    /// compute different signatures for the same state and re-register each other in turn.
    /// Missing or undecodable settings read as off (`NudgeTriggerSettings.failClosed`).
    static func isDailyReportEnabled(defaults: UserDefaults?) -> Bool {
        NudgeTriggerSettings.load(from: defaults).dailyReportEnabled
    }

    private struct TokenFilter {
        var applications: Set<ApplicationToken> = []
        var categories: Set<ActivityCategoryToken> = []
        var webDomains: Set<WebDomainToken> = []
    }

    /// `nil` means "skip this summary".
    private static func tokenFilter(for summary: GoalSummary) -> TokenFilter? {
        if summary.isSessionTimeout { return TokenFilter() }
        switch summary.targetType {
        case .total:
            return TokenFilter()
        case .app, .category:
            guard let data = summary.selectionData else {
                logger.error("goal \(summary.goalId) has no selection — skipped (re-select required)")
                return nil
            }
            guard let selection = SelectionCodec.decode(data: data) else {
                logger.error("goal \(summary.goalId) selection failed to decode — skipped (re-select required)")
                return nil
            }
            guard !SelectionCodec.isEmpty(selection) else {
                logger.error("goal \(summary.goalId) selection is empty — skipped (would monitor all usage)")
                return nil
            }
            return TokenFilter(
                applications: selection.applicationTokens,
                categories: selection.categoryTokens,
                webDomains: selection.webDomainTokens
            )
        }
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

    /// Bumped whenever what a registration contains changes shape (e.g. milestone
    /// naming), so upgraded installs re-register once.
    private static let signatureVersion = "v2"

    /// Order-independent fingerprint of the active set. Sorting matters: goal rows come
    /// back from Supabase in arbitrary order, and an order-sensitive signature would
    /// re-register (and so reset the day's counters) on every foreground.
    ///
    /// Each entry covers everything that changes the registered events: identity, target
    /// type, limit, and a fingerprint of the selection bytes — so editing a category's
    /// apps re-registers even when the limit is unchanged. Dates and frequency are not
    /// included: they only decide *whether* a goal is in the active set.
    static func signature(for summaries: [GoalSummary]) -> String {
        let entries = summaries
            .map { "\($0.eventName)|\($0.targetType.rawValue)|\($0.limitSeconds)|\(selectionFingerprint($0.selectionData))" }
            .sorted()
        return ([signatureVersion] + entries).joined(separator: ";")
    }

    /// The signature stamped by `register`: the goal signature, plus a daily-total entry
    /// when the report is on. Toggling the report therefore re-registers, while changing
    /// only the report time does not (the time is not part of what is registered). With
    /// the report off it equals `signature(for:)`, so upgraded installs do not re-register.
    static func registrationSignature(for active: [GoalSummary], dailyReportEnabled: Bool) -> String {
        let base = signature(for: active)
        guard dailyReportEnabled else { return base }
        return base + ";" + "\(dailyTotalEventName(minutes: dailyTotalStepMinutes))|\(dailyTotalStepMinutes)|\(dailyTotalMaxMinutes)"
    }

    /// `registrationSignature` for today's active subset of `catalog`, with the report
    /// toggle read from `defaults`. The one helper every staleness check uses.
    static func registrationSignature(
        catalog: [GoalSummary],
        defaults: UserDefaults?,
        now: Date,
        calendar: Calendar
    ) -> String {
        registrationSignature(
            for: activeSummaries(in: catalog, now: now, calendar: calendar),
            dailyReportEnabled: isDailyReportEnabled(defaults: defaults)
        )
    }

    /// SHA-256 hex of the stored selection bytes, or "-" when there is none. Hashes the
    /// persisted bytes rather than re-encoding the selection, because encoding a `Set`
    /// is not byte-stable across launches.
    static func selectionFingerprint(_ data: Data?) -> String {
        guard let data else { return "-" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    /// Reads the persisted catalog (unfiltered).
    static func loadSummaries(from defaults: UserDefaults?) -> [GoalSummary] {
        guard let data = defaults?.data(forKey: AppGroupKeys.goalsActive),
              let summaries = try? JSONDecoder().decode([GoalSummary].self, from: data) else {
            return []
        }
        return summaries
    }

    /// Writes the catalog without registering. The app calls this whenever it has
    /// freshly fetched data, so the extension's midnight re-arm sees edits that did not
    /// change today's active set (e.g. a temporary goal starting tomorrow).
    ///
    /// Callers must pass data they actually fetched — never an empty array standing in
    /// for a failed request (ADR-055).
    static func persistCatalog(_ catalog: [GoalSummary], defaults: UserDefaults?) {
        guard let defaults else { return }
        guard let data = try? JSONEncoder().encode(catalog) else {
            logger.error("failed to encode goal catalog")
            return
        }
        defaults.set(data, forKey: AppGroupKeys.goalsActive)
    }

    // MARK: - Registration

    /// Stops and restarts monitoring for `activityName` with today's active subset of
    /// `catalog`, persists the full catalog to the App Group for the extension, and
    /// records the day/signature stamps. Returns the number of events registered.
    ///
    /// The daily-report events are included when the report is on in the App Group
    /// settings (`isDailyReportEnabled`), so the extension's midnight re-arm gets them
    /// right with the app closed.
    ///
    /// **Stamps are written before `startMonitoring` runs, deliberately.** Restarting
    /// monitoring while its interval is active provokes another `intervalDidStart`,
    /// and the extension re-registers from that callback — so a stamp written
    /// afterwards would let the nested callback see the stale day and recurse. On
    /// failure the previous stamps are restored so the next opportunity retries.
    @discardableResult
    static func register(
        catalog: [GoalSummary],
        defaults: UserDefaults?,
        now: Date,
        calendar: Calendar,
        startMonitoring: (DeviceActivitySchedule, [DeviceActivityEvent.Name: DeviceActivityEvent]) throws -> Void
    ) throws -> Int {
        let active = activeSummaries(in: catalog, now: now, calendar: calendar)
        let dailyReportEnabled = isDailyReportEnabled(defaults: defaults)
        let events = registrationEvents(for: active, dailyReportEnabled: dailyReportEnabled)
        let previousDay = defaults?.string(forKey: AppGroupKeys.lastRegisteredDay)
        let previousSignature = defaults?.string(forKey: AppGroupKeys.lastRegisteredSignature)

        defaults?.set(dayStamp(for: now, calendar: calendar), forKey: AppGroupKeys.lastRegisteredDay)
        defaults?.set(
            registrationSignature(for: active, dailyReportEnabled: dailyReportEnabled),
            forKey: AppGroupKeys.lastRegisteredSignature
        )

        do {
            try startMonitoring(schedule(), events)
        } catch {
            defaults?.setOrRemove(previousDay, forKey: AppGroupKeys.lastRegisteredDay)
            defaults?.setOrRemove(previousSignature, forKey: AppGroupKeys.lastRegisteredSignature)
            throw error
        }

        persistCatalog(catalog, defaults: defaults)

        logger.log("registered monitoring — \(events.count) event(s), \(active.count) active of \(catalog.count) in catalog, daily report: \(dailyReportEnabled)")
        return events.count
    }

    /// Convenience overload driving a real `DeviceActivityCenter`.
    @discardableResult
    static func register(
        catalog: [GoalSummary],
        center: DeviceActivityCenter,
        defaults: UserDefaults?,
        now: Date,
        calendar: Calendar
    ) throws -> Int {
        try register(catalog: catalog, defaults: defaults, now: now, calendar: calendar) { schedule, events in
            center.stopMonitoring([activityName])
            try center.startMonitoring(activityName, during: schedule, events: events)
        }
    }

    /// Re-registers from the App Group catalog, but only when `isRegistrationStale` says
    /// it is needed. This is the path the monitor extension uses: it runs with no main
    /// app process and no network, so the last catalog and settings the app persisted are
    /// the best available source of truth.
    @discardableResult
    static func reregisterFromAppGroupIfNeeded(
        center: DeviceActivityCenter,
        defaults: UserDefaults?,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        reregisterFromAppGroupIfNeeded(defaults: defaults, now: now, calendar: calendar) { schedule, events in
            center.stopMonitoring([activityName])
            try center.startMonitoring(activityName, during: schedule, events: events)
        }
    }

    /// Testable core of the extension re-arm. An empty catalog is skipped (nothing the
    /// app wrote to arm) unless the daily report is on, which needs no goals.
    @discardableResult
    static func reregisterFromAppGroupIfNeeded(
        defaults: UserDefaults?,
        now: Date,
        calendar: Calendar,
        startMonitoring: (DeviceActivitySchedule, [DeviceActivityEvent.Name: DeviceActivityEvent]) throws -> Void
    ) -> Bool {
        let catalog = loadSummaries(from: defaults)
        guard !catalog.isEmpty || isDailyReportEnabled(defaults: defaults) else {
            logger.error("no goal summaries in App Group and daily report off — skipping re-registration")
            return false
        }

        let stale = isRegistrationStale(
            lastDay: defaults?.string(forKey: AppGroupKeys.lastRegisteredDay),
            lastSignature: defaults?.string(forKey: AppGroupKeys.lastRegisteredSignature),
            today: dayStamp(for: now, calendar: calendar),
            signature: registrationSignature(catalog: catalog, defaults: defaults, now: now, calendar: calendar)
        )
        guard stale else { return false }

        do {
            try register(catalog: catalog, defaults: defaults, now: now, calendar: calendar, startMonitoring: startMonitoring)
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

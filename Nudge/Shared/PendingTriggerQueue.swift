import Foundation
import os

/// The Strategy 2 queue (ADR-034) at `AppGroupKeys.triggersPending`: written by the
/// monitor extension, drained by the app's `NudgeTriggerService`.
///
/// Compiled into the app and the extensions via `Shared/` (ADR-056), so the reader, the
/// writer and the scheduling rule cannot drift. Everything except `load`/`save`/`append`
/// is pure and unit-tested.
enum PendingTriggerQueue {

    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "PendingTriggerQueue")

    /// Serialises in-process read-modify-write of the queue (several extension callbacks
    /// can run at once). Cross-process safety is the drain's re-load-before-save.
    private static let lock = NSLock()

    // MARK: - Persistence

    /// Missing or undecodable → empty.
    static func load(from defaults: UserDefaults?) -> [PendingTrigger] {
        guard let data = defaults?.data(forKey: AppGroupKeys.triggersPending),
              let triggers = try? JSONDecoder().decode([PendingTrigger].self, from: data) else {
            return []
        }
        return triggers
    }

    /// An empty queue removes the key.
    static func save(_ triggers: [PendingTrigger], to defaults: UserDefaults?) {
        guard let defaults else { return }
        guard !triggers.isEmpty else {
            defaults.removeObject(forKey: AppGroupKeys.triggersPending)
            return
        }
        guard let data = try? JSONEncoder().encode(triggers) else {
            logger.error("failed to encode pending triggers")
            return
        }
        defaults.set(data, forKey: AppGroupKeys.triggersPending)
    }

    /// Appends one trigger. Returns the queue size afterwards.
    @discardableResult
    static func append(_ trigger: PendingTrigger, to defaults: UserDefaults?) -> Int {
        lock.lock()
        defer { lock.unlock() }

        var pending = load(from: defaults)
        pending.append(trigger)
        save(pending, to: defaults)
        return pending.count
    }

    // MARK: - Drain selection (pure)

    struct Partition: Equatable {
        /// Send now.
        var due: [PendingTrigger] = []
        /// Not yet due (`notBefore` in the future): keep queued, untouched.
        var deferred: [PendingTrigger] = []
        /// Never send; remove from the queue.
        var dropped: [PendingTrigger] = []
    }

    /// Splits the queue for one drain, preserving order within each group.
    ///
    /// A daily report is **dropped** when the report has since been turned off (the user
    /// withdrew consent to the text), or when it has expired: its copy says "yesterday",
    /// which is only true on the day it was due (`DailyReport.isExpired`).
    static func partition(
        _ triggers: [PendingTrigger],
        now: Date,
        calendar: Calendar,
        dailyReportEnabled: Bool
    ) -> Partition {
        var result = Partition()
        for trigger in triggers {
            if trigger.eventName == DailyReport.triggerEventName,
               !dailyReportEnabled || DailyReport.isExpired(trigger, now: now, calendar: calendar) {
                result.dropped.append(trigger)
            } else if trigger.isDue(at: now) {
                result.due.append(trigger)
            } else {
                result.deferred.append(trigger)
            }
        }
        return result
    }

    // MARK: - BG task scheduling (pure)

    /// `earliestBeginDate` for the nudge-trigger BG task: the earliest future `notBefore`
    /// when nothing in the queue is due yet, otherwise `nil` (run as soon as iOS allows —
    /// a due trigger must never wait behind a later one). An empty queue is also `nil`,
    /// which keeps the pre-5E-2 behaviour.
    static func earliestBeginDate(for triggers: [PendingTrigger], now: Date) -> Date? {
        guard !triggers.isEmpty, !triggers.contains(where: { $0.isDue(at: now) }) else { return nil }
        return triggers.compactMap(\.notBefore).min()
    }
}

import Foundation

/// Records which threshold side effects (notification, friend SMS, BG task) already
/// ran today, so each runs at most once per day per (event, threshold).
///
/// **Why this exists (ADR-054 amendment):** every `DeviceActivityEvent` is built with
/// `includesPastActivity: true`, so a mid-day re-registration counts usage since
/// midnight instead of handing the user a fresh full limit. The cost is that a
/// threshold already passed today fires again, immediately, on every
/// re-registration. Without this store each of those would re-send the friend SMS.
///
/// Compiled into both the app and the monitor extension (`Shared/`). The extension
/// writes it from `eventDidReachThreshold`; `MonitoringPlan.register` prunes it (once a day).
///
/// Storage: `AppGroupKeys.firedKey(day:)` → JSON-encoded sorted `[String]` of dedup
/// keys. An unreadable value reads as empty — the worst case is one duplicate
/// notification, never a crash or a key that can never fire again.
struct FiredEventStore {

    /// Days kept before today. Today and the 2 previous days survive a prune; a
    /// little slack covers a late callback or a clock/time-zone change near midnight.
    static let retentionDays = 2

    /// Serialises test-and-set. Several thresholds can cross in the same instant
    /// after a re-registration, and without the lock two callbacks could both read
    /// "not fired" and both send. Static because each callback builds its own store.
    private static let lock = NSLock()

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - Keys

    /// `"<eventName>@<thresholdSeconds>"`. The threshold is part of the key on
    /// purpose (user decision 2026-11-23): a raised limit notifies again at the new
    /// limit, a limit lowered below today's usage notifies once immediately, and an
    /// unchanged limit never repeats.
    static func dedupKey(eventName: String, thresholdSeconds: Int) -> String {
        "\(eventName)@\(thresholdSeconds)"
    }

    /// Key for an event with no matching goal ("Nudge misconfigured"), so that
    /// warning cannot repeat on every re-registration either.
    static func unmatchedKey(eventName: String) -> String {
        "\(eventName)@unmatched"
    }

    // MARK: - Read / test-and-set

    func hasFired(_ key: String, onDay day: String) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return load(day: day).contains(key)
    }

    /// Records `key` for `day`. Returns `true` only for the call that inserted it —
    /// callers run side effects only on `true`.
    @discardableResult
    func markFired(_ key: String, onDay day: String) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        var fired = load(day: day)
        guard fired.insert(key).inserted else { return false }
        if let data = try? JSONEncoder().encode(fired.sorted()) {
            defaults.set(data, forKey: AppGroupKeys.firedKey(day: day))
        }
        return true
    }

    // MARK: - Pruning

    /// Removes fired-event records more than `retentionDays` before `today`'s local
    /// day, plus malformed keys under `AppGroupKeys.firedKeyPrefix`. Keys outside
    /// that prefix are never touched.
    func prune(keepingDaysFrom today: Date, calendar: Calendar) {
        guard let oldestKept = calendar.date(byAdding: .day, value: -Self.retentionDays, to: today) else {
            return
        }
        // "yyyy-MM-dd" stamps sort chronologically as plain strings.
        let cutoff = MonitoringPlan.dayStamp(for: oldestKept, calendar: calendar)
        let prefix = AppGroupKeys.firedKeyPrefix

        Self.lock.lock()
        defer { Self.lock.unlock() }

        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            let day = String(key.dropFirst(prefix.count))
            if !Self.isDayStamp(day) || day < cutoff {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// `prune`, at most once per local day (stamped in `AppGroupKeys.firedPruneDay`).
    /// `prune` enumerates every key in the domain (`dictionaryRepresentation()`, which also
    /// loads the app and global domains), and registration runs on every foreground that
    /// needs it, so doing it once a day keeps that scan off the common path. Returns whether
    /// it pruned.
    @discardableResult
    func pruneIfNeeded(keepingDaysFrom today: Date, calendar: Calendar) -> Bool {
        let day = MonitoringPlan.dayStamp(for: today, calendar: calendar)
        guard defaults.string(forKey: AppGroupKeys.firedPruneDay) != day else { return false }
        prune(keepingDaysFrom: today, calendar: calendar)
        defaults.set(day, forKey: AppGroupKeys.firedPruneDay)
        return true
    }

    // MARK: - Private

    /// Caller must hold `lock`.
    private func load(day: String) -> Set<String> {
        guard let data = defaults.data(forKey: AppGroupKeys.firedKey(day: day)),
              let keys = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(keys)
    }

    /// Whether `value` has the "yyyy-MM-dd" shape `MonitoringPlan.dayStamp` writes.
    private static func isDayStamp(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }
}

import Foundation

/// Day-scoped goal progress and milestone dedup, kept in the App Group (Phase 3 G4).
///
/// - `nudge.progress.<day>` → `{goalId: highestPercent}`. Written by the monitor
///   extension when a milestone fires; read by the app's Goals list (`progress(…)`).
///   Merging keeps the maximum, because a mid-day re-registration restarts counting and
///   lower milestones fire again.
/// - `nudge.fired.<day>` → event names whose side effects already ran that day, so a
///   re-registration can never produce a second notification or nudge.
///
/// Everything is keyed by the local calendar day (`MonitoringPlan.dayStamp`). Values are
/// JSON, like the rest of the App Group. Unreadable values read as empty rather than
/// failing: losing a progress hint is harmless, crashing the extension is not.
struct GoalProgressStore {

    /// Keys older than this many days before today are removed by `prune`.
    static let retentionDays = 2

    /// Serialises read-modify-write cycles within one process. Several thresholds can
    /// cross at once (e.g. a goal edit re-registers and p10–p50 fire together).
    private static let lock = NSLock()

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - Progress (read API for the Goals list)

    /// `{goalId: highestPercent}` recorded on `day`. Missing goals have no milestone yet
    /// (under 10%). Unknown ids (deleted goals) are the caller's to ignore.
    func progress(onDay day: String) -> [Int: Int] {
        guard let data = defaults.data(forKey: AppGroupKeys.progressKey(day: day)),
              let raw = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        var result: [Int: Int] = [:]
        for (key, value) in raw {
            if let id = Int(key) { result[id] = value }
        }
        return result
    }

    /// Today's progress by the local calendar day.
    func progress(now: Date, calendar: Calendar) -> [Int: Int] {
        progress(onDay: MonitoringPlan.dayStamp(for: now, calendar: calendar))
    }

    static func merged(_ progress: [Int: Int], goalId: Int, percent: Int) -> [Int: Int] {
        var result = progress
        result[goalId] = max(result[goalId] ?? 0, percent)
        return result
    }

    func recordProgress(goalId: Int, percent: Int, day: String) {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        let updated = Self.merged(progress(onDay: day), goalId: goalId, percent: percent)
        let raw = Dictionary(uniqueKeysWithValues: updated.map { (String($0.key), $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        defaults.set(data, forKey: AppGroupKeys.progressKey(day: day))
    }

    // MARK: - Dedup

    func hasFired(_ eventName: String, onDay day: String) -> Bool {
        firedEvents(onDay: day).contains(eventName)
    }

    /// Test-and-set: records `eventName` as fired on `day`. Returns `true` when this call
    /// recorded it, `false` when it had already fired that day (caller skips side effects).
    @discardableResult
    func markFired(_ eventName: String, onDay day: String) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        var fired = firedEvents(onDay: day)
        guard fired.insert(eventName).inserted else { return false }
        guard let data = try? JSONEncoder().encode(fired.sorted()) else { return true }
        defaults.set(data, forKey: AppGroupKeys.firedKey(day: day))
        return true
    }

    private func firedEvents(onDay day: String) -> Set<String> {
        guard let data = defaults.data(forKey: AppGroupKeys.firedKey(day: day)),
              let names = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(names)
    }

    // MARK: - Pruning

    /// Removes progress and dedup keys for days more than `retentionDays` before the local
    /// day of `today` (so today and the two previous days are kept). Malformed keys under
    /// our prefixes are removed too. Other App Group keys are never touched.
    func prune(keepingDaysFrom today: Date, calendar: Calendar) {
        guard let cutoffDate = calendar.date(byAdding: .day, value: -Self.retentionDays, to: today) else { return }
        let cutoff = MonitoringPlan.dayStamp(for: cutoffDate, calendar: calendar)

        Self.lock.lock()
        defer { Self.lock.unlock() }

        for key in defaults.dictionaryRepresentation().keys {
            guard let day = Self.day(fromKey: key) else { continue }
            if !Self.isDayStamp(day) || day < cutoff {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// The day suffix of a progress/fired key, or `nil` for any other key.
    private static func day(fromKey key: String) -> String? {
        for prefix in [AppGroupKeys.progressKeyPrefix, AppGroupKeys.firedKeyPrefix] where key.hasPrefix(prefix) {
            return String(key.dropFirst(prefix.count))
        }
        return nil
    }

    private static func isDayStamp(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count == 10, chars[4] == "-", chars[7] == "-" else { return false }
        return chars.enumerated().allSatisfy { index, ch in index == 4 || index == 7 || ch.isASCII && ch.isNumber }
    }
}

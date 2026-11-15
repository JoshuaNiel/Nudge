import Foundation

/// `goalId → notifyPercent → messages`. Messages are ordered by reminder id within each
/// (goal, percent), so the round-robin order does not depend on database row order.
typealias WhyRemindersByGoal = [Int: [Int: [String]]]

/// JSON coding of the `nudge.reminders.byGoal` App Group payload (Phase 4).
///
/// `Dictionary` with `Int` keys encodes through a keyed container, so the JSON is
/// `{"42": {"80": ["…"]}}` — the shape documented in `AppGroupKeys.remindersByGoal`.
enum WhyReminderPayload {

    static func encode(_ byGoal: WhyRemindersByGoal) -> Data? {
        try? JSONEncoder().encode(byGoal)
    }

    static func decode(_ data: Data) -> WhyRemindersByGoal? {
        try? JSONDecoder().decode(WhyRemindersByGoal.self, from: data)
    }
}

/// Round-robin choice among the whys at one (goal, percent).
enum WhyReminderRotation {

    struct Selection: Equatable {
        /// Index of the message to show now.
        let index: Int
        /// Index to store for the next time this (goal, percent) fires.
        let next: Int
    }

    /// `nil` when there is nothing to show. A stored index at or beyond `count` (whys were
    /// deleted since it was written) wraps around; a negative (corrupt) one starts over.
    static func select(count: Int, storedIndex: Int?) -> Selection? {
        guard count > 0 else { return nil }
        let stored = max(0, storedIndex ?? 0)
        let index = stored % count
        return Selection(index: index, next: (index + 1) % count)
    }

    /// Key in the `nudge.reminders.rr` dictionary.
    static func key(goalId: Int, percent: Int) -> String {
        "\(goalId).\(percent)"
    }
}

/// App Group access for why-reminders: the main app writes the payload; the monitor
/// extension reads it and advances the rotation.
///
/// Unreadable values read as empty rather than failing — a missing reminder is harmless,
/// a crashing extension is not (same policy as `GoalProgressStore`).
struct WhyReminderStore {

    /// Serialises the rotation's read-modify-write within one process: several milestone
    /// thresholds can cross at once (e.g. after a re-registration).
    private static let lock = NSLock()

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - Payload

    func byGoal() -> WhyRemindersByGoal {
        guard let data = defaults.data(forKey: AppGroupKeys.remindersByGoal) else { return [:] }
        return WhyReminderPayload.decode(data) ?? [:]
    }

    func messages(goalId: Int, percent: Int) -> [String] {
        byGoal()[goalId]?[percent] ?? []
    }

    /// Replaces the payload. The rotation is kept: `WhyReminderRotation` wraps an index
    /// that no longer fits, so an edit never needs to reset it.
    func write(_ byGoal: WhyRemindersByGoal) {
        guard let data = WhyReminderPayload.encode(byGoal) else { return }
        defaults.set(data, forKey: AppGroupKeys.remindersByGoal)
    }

    /// Removes the payload and the rotation (sign-out).
    func clear() {
        defaults.removeObject(forKey: AppGroupKeys.remindersByGoal)
        defaults.removeObject(forKey: AppGroupKeys.remindersRoundRobin)
    }

    // MARK: - Rotation

    /// The why to show for this (goal, percent), advancing the stored rotation. `nil` (and
    /// nothing stored) when the user has no why there.
    func nextMessage(goalId: Int, percent: Int) -> String? {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        let candidates = messages(goalId: goalId, percent: percent)
        let key = WhyReminderRotation.key(goalId: goalId, percent: percent)
        var rotation = storedRotation()
        guard let selection = WhyReminderRotation.select(count: candidates.count, storedIndex: rotation[key]) else {
            return nil
        }

        rotation[key] = selection.next
        if let data = try? JSONEncoder().encode(rotation) {
            defaults.set(data, forKey: AppGroupKeys.remindersRoundRobin)
        }
        return candidates[selection.index]
    }

    private func storedRotation() -> [String: Int] {
        guard let data = defaults.data(forKey: AppGroupKeys.remindersRoundRobin),
              let rotation = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return rotation
    }
}

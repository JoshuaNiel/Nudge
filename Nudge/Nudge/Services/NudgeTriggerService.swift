import Foundation
import os

// MARK: - PendingTrigger store

/// Abstraction over the App Group persistence for pending triggers so the drain
/// logic can be unit-tested without the App Group entitlement.
protocol PendingTriggerStore {
    func load() -> [PendingTrigger]
    func save(_ triggers: [PendingTrigger])
}

/// Production store: reads/writes a JSON-encoded `[PendingTrigger]` in the shared
/// App Group UserDefaults at `AppGroupKeys.triggersPending`.
final class AppGroupPendingTriggerStore: PendingTriggerStore {

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroupKeys.suiteName)
    }

    func load() -> [PendingTrigger] {
        MonitoringPlan.loadPendingTriggers(from: defaults)
    }

    func save(_ triggers: [PendingTrigger]) {
        guard let defaults else { return }
        if triggers.isEmpty {
            defaults.removeObject(forKey: AppGroupKeys.triggersPending)
            return
        }
        guard let data = try? JSONEncoder().encode(triggers) else { return }
        defaults.set(data, forKey: AppGroupKeys.triggersPending)
    }
}

// MARK: - Protocol

protocol NudgeTriggerServiceProtocol {
    /// Sends any pending nudge triggers to the user's accepted friends and removes
    /// the ones that were fully processed. Safe to call repeatedly and concurrently:
    /// only one drain runs at a time.
    func drainPendingTriggers(userId: UUID) async
}

// MARK: - Service

/// Drains the Strategy 2 queue the monitor extension writes (ADR-034).
///
/// Rules (phase-1 spec, "Draining the trigger queue safely"):
/// 1. A trigger from an earlier local day than now is dropped unsent.
/// 2. The first failed send ends the drain; everything unprocessed stays queued.
/// 3. Each successful send is recorded in `sentFriendIds` before moving on, and a
///    trigger is done once every *currently accepted* friend is in that list.
/// 4. Only one drain runs at a time in the process.
///
/// The extension may append while a drain runs, so every write is a
/// read-modify-write against a fresh `store.load()`, matched by
/// `(eventName, timestamp)`. Entries the drain never saw are never dropped.
@MainActor
final class NudgeTriggerService: NudgeTriggerServiceProtocol {

    /// Static because every caller (foreground, BG task) creates its own instance;
    /// an instance flag would not stop two drains double-sending.
    private static var isDraining = false

    private let store: PendingTriggerStore
    private let nudgeService: NudgeServiceProtocol
    private let friendService: FriendServiceProtocol
    private let now: () -> Date
    private let calendar: Calendar

    private let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "NudgeTriggerService")

    // Production init (ADR-028 two-init pattern).
    init() {
        self.store = AppGroupPendingTriggerStore()
        self.nudgeService = NudgeService()
        self.friendService = FriendService()
        self.now = Date.init
        self.calendar = .current
    }

    // Test / dependency-injection init.
    init(
        store: PendingTriggerStore,
        nudgeService: NudgeServiceProtocol,
        friendService: FriendServiceProtocol,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.store = store
        self.nudgeService = nudgeService
        self.friendService = friendService
        self.now = now
        self.calendar = calendar
    }

    func drainPendingTriggers(userId: UUID) async {
        guard !Self.isDraining else {
            logger.debug("drain already in flight — skipping")
            return
        }
        Self.isDraining = true
        defer { Self.isDraining = false }

        let loaded = store.load()
        guard !loaded.isEmpty else { return }

        let pending = dropExpired(from: loaded)
        guard !pending.isEmpty else { return }

        logger.debug("draining \(pending.count) pending trigger(s)")

        // Fetch accepted friends. On failure, retain everything to retry later.
        guard let allFriends = try? await friendService.fetchFriends(userId: userId) else {
            logger.error("friend fetch failed — retaining \(pending.count) trigger(s) for retry")
            return
        }
        let accepted = allFriends.filter { $0.status == .accepted }

        // Nobody to notify: nothing more will ever come of these triggers, so clear
        // the ones we saw (not any the extension appended meanwhile).
        guard !accepted.isEmpty else {
            logger.debug("no accepted friends — clearing \(pending.count) pending trigger(s)")
            updateStore { current in
                current.filter { candidate in !pending.contains { $0.isSameEntry(as: candidate) } }
            }
            return
        }

        var sentCount = 0
        var completedCount = 0

        for trigger in pending {
            var sentIds = trigger.sentFriendIds
            for friend in accepted where !sentIds.contains(friend.id) {
                do {
                    try await nudgeService.sendNudge(friendId: friend.id, report: trigger.report)
                } catch {
                    logger.error("sendNudge failed for friend \(friend.id): \(error.localizedDescription, privacy: .public) — stopping drain (sent \(sentCount), completed \(completedCount)/\(pending.count))")
                    return
                }
                sentCount += 1
                sentIds.append(friend.id)
                recordSent(sentIds, for: trigger)
            }

            // Every currently accepted friend has it; ids of removed friends are ignored.
            updateStore { current in current.filter { !$0.isSameEntry(as: trigger) } }
            completedCount += 1
        }

        logger.debug("drain complete — sent \(sentCount), completed \(completedCount)/\(pending.count)")
    }

    // MARK: - Private

    /// Removes triggers from an earlier local calendar day than now (a nudge about
    /// yesterday is misleading today) and returns the ones still worth sending.
    private func dropExpired(from triggers: [PendingTrigger]) -> [PendingTrigger] {
        let today = MonitoringPlan.dayStamp(for: now(), calendar: calendar)
        let isExpired: (PendingTrigger) -> Bool = {
            MonitoringPlan.dayStamp(for: $0.timestamp, calendar: self.calendar) < today
        }
        let expired = triggers.filter(isExpired)
        guard !expired.isEmpty else { return triggers }

        updateStore { current in current.filter { !isExpired($0) } }
        logger.log("dropped \(expired.count) expired trigger(s) from before \(today, privacy: .public)")
        return triggers.filter { !isExpired($0) }
    }

    /// Persists send progress immediately, so a crash or a stopped drain never
    /// re-sends to a friend who already got this trigger.
    private func recordSent(_ sentIds: [Int], for trigger: PendingTrigger) {
        updateStore { current in
            current.map { candidate in
                guard candidate.isSameEntry(as: trigger) else { return candidate }
                var updated = candidate
                updated.sentFriendIds = sentIds
                return updated
            }
        }
    }

    /// Read-modify-write against a fresh load, so triggers the extension appended
    /// since the drain started are kept.
    private func updateStore(_ transform: ([PendingTrigger]) -> [PendingTrigger]) {
        store.save(transform(store.load()))
    }
}

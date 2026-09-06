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
        guard let data = defaults?.data(forKey: AppGroupKeys.triggersPending),
              let triggers = try? JSONDecoder().decode([PendingTrigger].self, from: data) else {
            return []
        }
        return triggers
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
    /// the ones that were fully processed. Safe to call repeatedly.
    func drainPendingTriggers(userId: UUID) async
}

// MARK: - Service

@MainActor
final class NudgeTriggerService: NudgeTriggerServiceProtocol {

    private let store: PendingTriggerStore
    private let nudgeService: NudgeServiceProtocol
    private let friendService: FriendServiceProtocol

    private let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "NudgeTriggerService")

    // Production init (ADR-028 two-init pattern).
    init() {
        self.store = AppGroupPendingTriggerStore()
        self.nudgeService = NudgeService()
        self.friendService = FriendService()
    }

    // Test / dependency-injection init.
    init(
        store: PendingTriggerStore,
        nudgeService: NudgeServiceProtocol,
        friendService: FriendServiceProtocol
    ) {
        self.store = store
        self.nudgeService = nudgeService
        self.friendService = friendService
    }

    func drainPendingTriggers(userId: UUID) async {
        let pending = store.load()
        guard !pending.isEmpty else { return }

        logger.debug("draining \(pending.count) pending trigger(s)")

        // Fetch accepted friends. On failure, retain everything to retry later.
        guard let allFriends = try? await friendService.fetchFriends(userId: userId) else {
            logger.error("friend fetch failed — retaining \(pending.count) trigger(s) for retry")
            return
        }
        let accepted = allFriends.filter { $0.status == .accepted }

        // Nobody to notify: nothing more will ever come of these triggers, so clear.
        guard !accepted.isEmpty else {
            logger.debug("no accepted friends — clearing \(pending.count) pending trigger(s)")
            store.save([])
            return
        }

        var processed: [PendingTrigger] = []
        var sentCount = 0
        var failureCount = 0

        for trigger in pending {
            var allSucceeded = true
            for friend in accepted {
                do {
                    try await nudgeService.sendNudge(friendId: friend.id, report: trigger.report)
                    sentCount += 1
                } catch {
                    allSucceeded = false
                    failureCount += 1
                    logger.error("sendNudge failed for friend \(friend.id): \(error.localizedDescription, privacy: .public)")
                }
            }
            if allSucceeded {
                processed.append(trigger)
            }
        }

        logger.debug("drain complete — sent \(sentCount), failures \(failureCount), processed \(processed.count)/\(pending.count)")

        guard !processed.isEmpty else { return }

        // Read-modify-write: re-load so we don't drop triggers the extension may have
        // appended while we were draining. Only remove entries we actually processed.
        let current = store.load()
        let remaining = current.filter { candidate in
            !processed.contains { $0.eventName == candidate.eventName && $0.timestamp == candidate.timestamp }
        }
        store.save(remaining)
        logger.debug("removed \(current.count - remaining.count) processed trigger(s); \(remaining.count) remaining")
    }
}

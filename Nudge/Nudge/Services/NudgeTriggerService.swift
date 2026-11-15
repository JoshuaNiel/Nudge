import Foundation
import os

// MARK: - PendingTrigger store

/// Abstraction over the App Group persistence for pending triggers so the drain
/// logic can be unit-tested without the App Group entitlement.
protocol PendingTriggerStore {
    func load() -> [PendingTrigger]
    func save(_ triggers: [PendingTrigger])
}

/// Production store: the shared App Group queue (`PendingTriggerQueue`).
final class AppGroupPendingTriggerStore: PendingTriggerStore {

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroupKeys.suiteName)
    }

    func load() -> [PendingTrigger] {
        PendingTriggerQueue.load(from: defaults)
    }

    func save(_ triggers: [PendingTrigger]) {
        PendingTriggerQueue.save(triggers, to: defaults)
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
    private let now: () -> Date
    private let calendar: Calendar
    /// The App Group settings mirror — the same source the extension reads — so turning
    /// the daily report off drops reports already queued.
    private let triggerSettings: () -> NudgeTriggerSettings

    private let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "NudgeTriggerService")

    // Production init (ADR-028 two-init pattern).
    init() {
        self.store = AppGroupPendingTriggerStore()
        self.nudgeService = NudgeService()
        self.friendService = FriendService()
        self.now = { Date() }
        self.calendar = .current
        self.triggerSettings = { NudgeTriggerSettings.load(from: UserDefaults(suiteName: AppGroupKeys.suiteName)) }
    }

    // Test / dependency-injection init.
    init(
        store: PendingTriggerStore,
        nudgeService: NudgeServiceProtocol,
        friendService: FriendServiceProtocol,
        now: @escaping () -> Date = { Date() },
        calendar: Calendar = .current,
        triggerSettings: (() -> NudgeTriggerSettings)? = nil
    ) {
        self.store = store
        self.nudgeService = nudgeService
        self.friendService = friendService
        self.now = now
        self.calendar = calendar
        let failClosed = NudgeTriggerSettings.failClosed   // default: report off
        self.triggerSettings = triggerSettings ?? { failClosed }
    }

    /// Sends the triggers that are due (`notBefore` nil or passed) and leaves the rest
    /// queued untouched (Phase 5E-2). Daily reports that were turned off or have expired
    /// are removed without sending — before any network call, so a failed friend fetch
    /// cannot keep them alive.
    func drainPendingTriggers(userId: UUID) async {
        let pending = store.load()
        guard !pending.isEmpty else { return }

        let partition = PendingTriggerQueue.partition(
            pending,
            now: now(),
            calendar: calendar,
            dailyReportEnabled: triggerSettings().dailyReportEnabled
        )
        logger.debug("draining — due \(partition.due.count), deferred \(partition.deferred.count), dropped \(partition.dropped.count)")

        if !partition.dropped.isEmpty {
            remove(partition.dropped)
        }
        guard !partition.due.isEmpty else { return }

        // Fetch accepted friends. On failure, retain everything to retry later.
        guard let allFriends = try? await friendService.fetchFriends(userId: userId) else {
            logger.error("friend fetch failed — retaining \(partition.due.count) due trigger(s) for retry")
            return
        }
        let accepted = allFriends.filter { $0.status == .accepted }

        // Nobody to notify: nothing more will ever come of the due triggers, so clear them.
        // Deferred ones stay: a friend may accept before they come due.
        guard !accepted.isEmpty else {
            logger.debug("no accepted friends — clearing \(partition.due.count) due trigger(s)")
            remove(partition.due)
            return
        }

        var processed: [PendingTrigger] = []
        var sentCount = 0
        var failureCount = 0

        for trigger in partition.due {
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

        logger.debug("drain complete — sent \(sentCount), failures \(failureCount), processed \(processed.count)/\(partition.due.count)")

        guard !processed.isEmpty else { return }
        remove(processed)
    }

    /// Read-modify-write: re-load so we don't drop triggers the extension may have
    /// appended while we were draining. Only removes the given entries, matched by
    /// (eventName, timestamp).
    private func remove(_ triggers: [PendingTrigger]) {
        let current = store.load()
        let remaining = current.filter { candidate in
            !triggers.contains { $0.eventName == candidate.eventName && $0.timestamp == candidate.timestamp }
        }
        store.save(remaining)
        logger.debug("removed \(current.count - remaining.count) trigger(s); \(remaining.count) remaining")
    }
}

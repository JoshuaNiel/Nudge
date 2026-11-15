import Foundation
import Combine
import os

// MARK: - NudgeHistoryMerge

/// Pure rules for folding real-time nudge events into a friend's history list.
enum NudgeHistoryMerge {
    /// History order: newest `sent_timestamp` first (matches `FriendService.fetchNudgeHistory`),
    /// ties broken by higher id first so the order is deterministic.
    static func sorted(_ nudges: [Nudge]) -> [Nudge] {
        nudges.sorted { ($0.sentTimestamp, $0.id) > ($1.sentTimestamp, $1.id) }
    }

    /// Returns `nudges` with `change` applied, kept in history order.
    ///
    /// - INSERT of a new id → added. INSERT of an id already present → no-op (the row we hold
    ///   is at least as new — e.g. a refetch already returned it as `replied`).
    /// - UPDATE of a known id → replaced. UPDATE of an unknown id → inserted (we missed its
    ///   INSERT while disconnected / before the first load; the UPDATE is the freshest state).
    /// - Records for any other friend → ignored (defensive; the channel is already filtered).
    /// - `.subscribed` → unchanged (the caller refetches instead).
    static func applying(_ change: NudgeChange, to nudges: [Nudge], friendId: Int) -> [Nudge] {
        switch change {
        case .subscribed:
            return nudges

        case .inserted(let nudge):
            guard nudge.friendId == friendId,
                  !nudges.contains(where: { $0.id == nudge.id }) else { return nudges }
            return sorted(nudges + [nudge])

        case .updated(let nudge):
            guard nudge.friendId == friendId else { return nudges }
            var result = nudges
            if let index = result.firstIndex(where: { $0.id == nudge.id }) {
                result[index] = nudge
            } else {
                result.append(nudge)
            }
            return sorted(result)
        }
    }
}

// MARK: - NudgeHistoryViewModel

/// State for one friend's nudge history: initial load, pull-to-refresh / foreground refetch,
/// and live status updates from `NudgeRealtimeService` while the screen is visible.
@MainActor
final class NudgeHistoryViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "NudgeHistoryViewModel")

    @Published private(set) var nudges: [Nudge] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String? = nil

    /// True while `start()` is running, i.e. while the history screen is on screen.
    var isObserving: Bool { observerCount > 0 }

    let friendId: Int

    private let friendService: FriendServiceProtocol
    private let realtimeService: NudgeRealtimeServiceProtocol

    /// Counter, not a Bool: SwiftUI may start a new `.task` before the cancelled one has unwound.
    private var observerCount = 0
    /// Bumped by every fetch and every applied realtime change. A fetch whose generation is no
    /// longer current when it returns is discarded, so a slow response can't overwrite newer data.
    private var generation = 0

    // Production init — uses real services
    init(friendId: Int) {
        self.friendId = friendId
        self.friendService = FriendService()
        self.realtimeService = NudgeRealtimeService()
    }

    // Test init — accepts mocks
    init(
        friendId: Int,
        friendService: FriendServiceProtocol,
        realtimeService: NudgeRealtimeServiceProtocol
    ) {
        self.friendId = friendId
        self.friendService = friendService
        self.realtimeService = realtimeService
    }

    // MARK: - Lifecycle

    /// Run from the view's `.task`: loads history, then applies live changes until the task is
    /// cancelled (screen disappears) or the stream ends. Cancelling tears down the subscription.
    func start() async {
        observerCount += 1
        defer { observerCount -= 1 }

        // Subscribe first so the join overlaps the fetch; events buffer in the stream meanwhile.
        let changes = realtimeService.changes(friendId: friendId)

        // Re-appearing (e.g. tab switch back) keeps the current list on screen — no spinner.
        if nudges.isEmpty {
            await load()
        } else {
            await refresh()
        }

        for await change in changes {
            await apply(change)
        }
    }

    /// App returned to the foreground. Refetches only while the history screen is visible.
    func sceneDidBecomeActive() async {
        guard isObserving else { return }
        await refresh()
    }

    // MARK: - Fetching

    /// Initial load: full-screen spinner; a failure is shown as the screen's error.
    func load() async {
        error = nil
        isLoading = true
        defer { isLoading = false }
        await fetch()
    }

    /// Silent refetch (pull-to-refresh, foreground, realtime resubscribe). A failure keeps the
    /// current list and is only logged — unless there is nothing on screen, then it's shown.
    func refresh() async {
        await fetch()
    }

    private func fetch() async {
        generation += 1
        let fetchGeneration = generation
        do {
            let history = try await friendService.fetchNudgeHistory(friendId: friendId)
            guard fetchGeneration == generation else { return }
            nudges = NudgeHistoryMerge.sorted(history)
            error = nil
        } catch {
            guard fetchGeneration == generation, !Task.isCancelled else { return }
            Self.logger.error("Nudge history fetch failed: \(error.localizedDescription, privacy: .public)")
            if nudges.isEmpty {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Realtime

    private func apply(_ change: NudgeChange) async {
        if case .subscribed = change {
            // First join or a rejoin after reconnect: cover anything missed while not listening.
            await refresh()
            return
        }
        let merged = NudgeHistoryMerge.applying(change, to: nudges, friendId: friendId)
        guard merged != nudges else { return }
        generation += 1  // any fetch already in flight predates this change
        nudges = merged
        error = nil
    }
}

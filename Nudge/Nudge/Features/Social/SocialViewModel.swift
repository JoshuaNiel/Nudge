import Foundation
import Combine
import os

// MARK: - FriendListMerge

/// Pure rules for folding real-time friend events into the Friends list.
enum FriendListMerge {
    /// List order: newest `invitation_timestamp` first (matches `FriendService.fetchFriends`),
    /// ties broken by higher id first so the order is deterministic.
    static func sorted(_ friends: [Friend]) -> [Friend] {
        friends.sorted { ($0.invitationTimestamp, $0.id) > ($1.invitationTimestamp, $1.id) }
    }

    /// Returns `friends` with `change` applied, kept in list order.
    ///
    /// - INSERT of a new id → added. INSERT of an id already present → no-op (the row we hold
    ///   is at least as new — e.g. a refetch already returned it as accepted).
    /// - UPDATE of a known id → replaced (so `pending → accepted` moves it between sections and
    ///   a rename shows). UPDATE of an unknown id → inserted (its INSERT was missed while
    ///   disconnected / before the first load; the UPDATE is the freshest state).
    /// - A row whose status is `blocked` is never shown (same as the fetch): an UPDATE to
    ///   blocked removes it; a blocked INSERT / unknown blocked UPDATE is ignored.
    /// - Rows for any other user → ignored (defensive; RLS + the channel filter already apply).
    /// - `.subscribed` → unchanged (the caller refetches instead).
    static func applying(_ change: FriendChange, to friends: [Friend], userId: UUID) -> [Friend] {
        switch change {
        case .subscribed:
            return friends

        case .inserted(let friend):
            guard friend.userId == userId,
                  friend.status != .blocked,
                  !friends.contains(where: { $0.id == friend.id }) else { return friends }
            return sorted(friends + [friend])

        case .updated(let friend):
            guard friend.userId == userId else { return friends }
            var result = friends.filter { $0.id != friend.id }
            if friend.status != .blocked {
                result.append(friend)
            }
            return sorted(result)
        }
    }
}

// MARK: - SocialViewModel

/// State for the Friends tab: initial load, pull-to-refresh / foreground refetch, live
/// INSERT / UPDATE events from `FriendRealtimeService` while the tab is on screen, renames,
/// deletes, and resolving a reply push to the friend whose history should open.
///
/// The single source of truth for friends: the friend screen (`FriendDetailViewModel`) reads
/// its friend from `friends` rather than holding its own copy.
@MainActor
final class SocialViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "SocialViewModel")

    @Published private(set) var friends: [Friend] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String? = nil

    /// True while `start(userId:)` is running, i.e. while the Friends tab is on screen (the list
    /// or a friend screen pushed on it).
    var isObserving: Bool { observerCount > 0 }

    private let friendService: FriendServiceProtocol
    private let realtimeService: FriendRealtimeServiceProtocol

    /// Counter, not a Bool: SwiftUI may start a new `.task` before the cancelled one has unwound.
    private var observerCount = 0
    /// The user whose list is being observed (for the foreground refetch).
    private var observedUserId: UUID?
    /// Bumped by every fetch and every local / realtime change. A fetch whose generation is no
    /// longer current when it returns is discarded, so a slow response can't overwrite newer data.
    private var generation = 0

    // Production init — uses real services
    init() {
        self.friendService = FriendService()
        self.realtimeService = FriendRealtimeService()
    }

    // Test init — accepts mocks
    init(friendService: FriendServiceProtocol, realtimeService: FriendRealtimeServiceProtocol) {
        self.friendService = friendService
        self.realtimeService = realtimeService
    }

    // MARK: - Lifecycle

    /// Run from the view's `.task`: loads the list, calls `onInitialFetch` once (e.g. to open a
    /// pending push deep link against the loaded list), then applies live changes until the task
    /// is cancelled (Friends tab disappears) or the stream ends. Cancelling tears down the channel.
    func start(userId: UUID, onInitialFetch: () async -> Void = {}) async {
        observerCount += 1
        observedUserId = userId
        defer { observerCount -= 1 }

        // Subscribe first so the join overlaps the fetch; events buffer in the stream meanwhile.
        let changes = realtimeService.changes(userId: userId)

        // Re-appearing (e.g. tab switch back) keeps the current list on screen — no spinner.
        if friends.isEmpty {
            await load(userId: userId)
        } else {
            await refresh(userId: userId)
        }
        await onInitialFetch()

        for await change in changes {
            await apply(change, userId: userId)
        }
    }

    /// App returned to the foreground. Refetches only while the Friends tab is on screen.
    func sceneDidBecomeActive() async {
        guard isObserving, let observedUserId else { return }
        await refresh(userId: observedUserId)
    }

    // MARK: - Fetching

    /// Initial load: full-screen spinner; a failure is shown as the screen's error.
    func load(userId: UUID) async {
        error = nil
        isLoading = true
        defer { isLoading = false }
        _ = await fetch(userId: userId)
    }

    /// Silent refetch (pull-to-refresh, foreground, realtime resubscribe, after adding a friend).
    /// A failure keeps the current list and is only logged — unless there is nothing on screen,
    /// then it's shown.
    func refresh(userId: UUID) async {
        _ = await fetch(userId: userId)
    }

    /// Fetches the list and publishes it unless a newer fetch / change superseded it.
    /// Returns the fetched rows (sorted), or nil on failure. With `showsFailure == false` a
    /// failure is only logged, even when the list is empty.
    private func fetch(userId: UUID, showsFailure: Bool = true) async -> [Friend]? {
        generation += 1
        let fetchGeneration = generation
        do {
            let fetched = FriendListMerge.sorted(try await friendService.fetchFriends(userId: userId))
            if fetchGeneration == generation {
                friends = fetched
                error = nil
            }
            return fetched
        } catch {
            guard fetchGeneration == generation, !Task.isCancelled else { return nil }
            Self.logger.error("Friend list fetch failed: \(error.localizedDescription, privacy: .public)")
            if showsFailure && friends.isEmpty {
                self.error = error.localizedDescription
            }
            return nil
        }
    }

    // MARK: - Realtime

    private func apply(_ change: FriendChange, userId: UUID) async {
        if case .subscribed = change {
            // First join or a rejoin after reconnect: cover anything missed while not listening.
            await refresh(userId: userId)
            return
        }
        let merged = FriendListMerge.applying(change, to: friends, userId: userId)
        guard merged != friends else { return }
        generation += 1  // any fetch already in flight predates this change
        friends = merged
        error = nil
    }

    // MARK: - Push deep link

    /// Resolves a reply push's nudge to the accepted friend whose history should open.
    ///
    /// Returns nil — never sets `error` — when the nudge or friend can't be found or the
    /// lookup fails; the caller then just shows the friend list. If the friend isn't in the
    /// loaded list (it may be stale), the list is refetched once.
    func friendForNudge(id nudgeId: Int, userId: UUID) async -> Friend? {
        guard let friendId = try? await friendService.fetchFriendId(forNudgeId: nudgeId) else {
            return nil
        }
        if let friend = Self.acceptedFriend(id: friendId, in: friends) {
            return friend
        }
        // Failure here is deliberately silent (no error state) — the user stays on the list.
        guard let refreshed = await fetch(userId: userId, showsFailure: false) else { return nil }
        return Self.acceptedFriend(id: friendId, in: refreshed)
    }

    private static func acceptedFriend(id: Int, in friends: [Friend]) -> Friend? {
        friends.first { $0.id == id && $0.status == .accepted }
    }

    // MARK: - Friends

    /// Swipe-to-delete on the list. A failure is shown as the screen's error.
    func deleteFriend(_ friend: Friend) async {
        do {
            try await removeFriend(id: friend.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Deletes the friend (the database cascades their nudges) and drops it from the list right
    /// away. Throws on failure, leaving the list unchanged — the caller decides how to show it.
    func removeFriend(id: Int) async throws {
        try await friendService.deleteFriend(id: id)
        generation += 1  // a fetch already in flight may still include the deleted row
        friends.removeAll { $0.id == id }
    }

    /// Saves a new display name (already trimmed and validated by the caller) and shows it in the
    /// list right away. The realtime UPDATE echo is then a no-op (`FriendListMerge`). Throws on
    /// failure, leaving the list unchanged.
    func renameFriend(id: Int, to name: String) async throws {
        try await friendService.updateFriendName(id: id, name: name)
        generation += 1  // a fetch already in flight may still have the old name
        friends = friends.map { $0.id == id ? $0.renamed(to: name) : $0 }
    }
}

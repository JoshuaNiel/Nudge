import Foundation
import Combine

// MARK: - FriendScreenContent

/// What the friend screen shows for the friend's current (live) state.
enum FriendScreenContent: Equatable {
    /// Pending: no history and no nudge channel, just the awaiting-consent message.
    case awaitingConsent(Friend)
    /// Accepted: the live nudge history.
    case history(Friend)
    /// Blocked, deleted elsewhere, or dropped by a refresh: the screen pops back to the list.
    case gone

    static func resolve(friendId: Int, in friends: [Friend]) -> FriendScreenContent {
        guard let friend = friends.first(where: { $0.id == friendId }) else { return .gone }
        switch friend.status {
        case .pending:  return .awaitingConsent(friend)
        case .accepted: return .history(friend)
        case .blocked:  return .gone
        }
    }

    /// The friend being shown, or nil once gone.
    var friend: Friend? {
        switch self {
        case .awaitingConsent(let friend), .history(let friend): return friend
        case .gone: return nil
        }
    }
}

// MARK: - FriendDetailViewModel

/// State for one friend's screen. The friend itself is never copied: `content` is derived from
/// the shared `SocialViewModel.friends` (the Friends tab's live list), so pending → accepted,
/// renames, blocks and removals made anywhere show here immediately.
///
/// The nudge-history view model (and with it the realtime nudge channel) is created only once
/// the friend is accepted, so a pending friend never opens one.
@MainActor
final class FriendDetailViewModel: ObservableObject {
    @Published private(set) var content: FriendScreenContent
    @Published private(set) var isRemoving = false
    @Published private(set) var removeError: String? = nil

    /// Created the first time the friend is accepted; kept for the life of the screen.
    @Published private(set) var historyViewModel: NudgeHistoryViewModel? = nil

    let friendId: Int

    private let socialViewModel: SocialViewModel
    private let makeHistoryViewModel: (Int) -> NudgeHistoryViewModel
    private var friendsSubscription: AnyCancellable?

    // Production init — history uses the real services
    convenience init(friendId: Int, socialViewModel: SocialViewModel) {
        self.init(friendId: friendId, socialViewModel: socialViewModel) { id in
            NudgeHistoryViewModel(friendId: id)
        }
    }

    // Test init — injects how the history view model is built
    init(
        friendId: Int,
        socialViewModel: SocialViewModel,
        makeHistoryViewModel: @escaping (Int) -> NudgeHistoryViewModel
    ) {
        self.friendId = friendId
        self.socialViewModel = socialViewModel
        self.makeHistoryViewModel = makeHistoryViewModel
        self.content = .gone
        update(with: socialViewModel.friends)

        // `@Published` emits on willSet with the new value, always on the main actor (the
        // publisher's owner is `@MainActor`), so the screen updates in the same pass as the list.
        friendsSubscription = socialViewModel.$friends
            .dropFirst()  // the current value was applied above
            .sink { [weak self] friends in
                MainActor.assumeIsolated { self?.update(with: friends) }
            }
    }

    // MARK: - Live state

    private func update(with friends: [Friend]) {
        let resolved = FriendScreenContent.resolve(friendId: friendId, in: friends)
        if case .history = resolved, historyViewModel == nil {
            historyViewModel = makeHistoryViewModel(friendId)
        }
        if resolved != content {
            content = resolved
        }
    }

    // MARK: - Rename

    /// Saves a trimmed, validated name (see `RenameFriendModel`). The list — and so this screen —
    /// shows it right away. Throws on failure so the rename sheet can keep the edit.
    func rename(to name: String) async throws {
        try await socialViewModel.renameFriend(id: friendId, to: name)
    }

    // MARK: - Remove

    /// Deletes the friend. On success the friend leaves the list, `content` becomes `.gone` and
    /// the screen pops. On failure the friend stays and `removeError` is shown.
    func remove() async {
        removeError = nil
        isRemoving = true
        defer { isRemoving = false }
        do {
            try await socialViewModel.removeFriend(id: friendId)
        } catch {
            removeError = error.localizedDescription
        }
    }
}

// MARK: - RenameFriendModel

/// The rename sheet's form: the draft name, its validation hint, and the save state. A failed
/// save keeps the draft so the user can retry.
@MainActor
final class RenameFriendModel: ObservableObject {
    @Published var name: String
    @Published private(set) var isSaving = false
    @Published private(set) var error: String? = nil

    private let onSave: (String) async throws -> Void

    init(name: String, onSave: @escaping (String) async throws -> Void) {
        self.name = name
        self.onSave = onSave
    }

    /// Why the draft can't be saved (shown inline), or nil.
    var validationMessage: String? { name.friendNameValidationError }

    var canSave: Bool { validationMessage == nil && !isSaving }

    /// Saves the trimmed name. Returns true on success (the caller closes the sheet).
    func save() async -> Bool {
        guard canSave else { return false }
        error = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try await onSave(name.trimmedFriendName)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

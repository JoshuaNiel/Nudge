import Foundation
import Combine

@MainActor
class SocialViewModel: ObservableObject {
    @Published var friends: [Friend] = []
    @Published var isLoading = false
    @Published var error: String? = nil

    private let friendService: FriendServiceProtocol

    // Production init — uses real service
    init() {
        self.friendService = FriendService()
    }

    // Test init — accepts a mock
    init(friendService: FriendServiceProtocol) {
        self.friendService = friendService
    }

    func load(userId: UUID) async {
        error = nil
        isLoading = true
        defer { isLoading = false }
        do {
            friends = try await friendService.fetchFriends(userId: userId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Resolves a reply push's nudge to the accepted friend whose history should open.
    ///
    /// Returns nil — never sets `error` — when the nudge or friend can't be found or the
    /// lookup fails; the caller then just shows the friend list. If the friend isn't in the
    /// loaded list (it may be stale), the list is refetched once.
    func friendForNudge(id nudgeId: Int, userId: UUID) async -> Friend? {
        guard let friendId = try? await friendService.fetchFriendId(forNudgeId: nudgeId) else {
            return nil
        }
        if let friend = acceptedFriend(id: friendId) {
            return friend
        }
        guard let refreshed = try? await friendService.fetchFriends(userId: userId) else {
            return nil
        }
        friends = refreshed
        return acceptedFriend(id: friendId)
    }

    private func acceptedFriend(id: Int) -> Friend? {
        friends.first { $0.id == id && $0.status == .accepted }
    }

    func deleteFriend(_ friend: Friend) async {
        do {
            try await friendService.deleteFriend(id: friend.id)
            friends.removeAll { $0.id == friend.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

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

    func deleteFriend(_ friend: Friend) async {
        do {
            try await friendService.deleteFriend(id: friend.id)
            friends.removeAll { $0.id == friend.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

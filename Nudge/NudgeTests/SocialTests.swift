import Testing
import Foundation
@testable import Nudge

// MARK: - FriendStatus Raw Values

@Suite("FriendStatus")
@MainActor
struct FriendStatusTests {

    @Test func pendingRawValue() {
        #expect(FriendStatus.pending.rawValue == "pending")
    }

    @Test func acceptedRawValue() {
        #expect(FriendStatus.accepted.rawValue == "accepted")
    }

    @Test func blockedRawValue() {
        #expect(FriendStatus.blocked.rawValue == "blocked")
    }
}

// MARK: - NudgeType Raw Values

@Suite("NudgeType")
@MainActor
struct NudgeTypeTests {

    @Test func shameRawValue() {
        #expect(NudgeType.shame.rawValue == "shame")
    }

    @Test func encouragementRawValue() {
        #expect(NudgeType.encouragement.rawValue == "encouragement")
    }

    @Test func customRawValue() {
        #expect(NudgeType.custom.rawValue == "custom")
    }
}

// MARK: - NudgeStatus Raw Values

@Suite("NudgeStatus")
@MainActor
struct NudgeStatusTests {

    @Test func sentToFriendRawValue() {
        #expect(NudgeStatus.sentToFriend.rawValue == "sent_to_friend")
    }

    @Test func repliedRawValue() {
        #expect(NudgeStatus.replied.rawValue == "replied")
    }

    @Test func replyDeliveredRawValue() {
        #expect(NudgeStatus.replyDelivered.rawValue == "reply_delivered")
    }

    @Test func failedRawValue() {
        #expect(NudgeStatus.failed.rawValue == "failed")
    }
}

// MARK: - Friend Model Coding

@Suite("Friend Coding")
@MainActor
struct FriendCodingTests {

    private let sampleJSON = """
    {
        "id": 42,
        "user_id": "00000000-0000-0000-0000-000000000001",
        "friend_name": "Alice",
        "friend_phone_number": "+18015551234",
        "status": "accepted",
        "invitation_timestamp": "2026-04-13T12:00:00Z"
    }
    """

    @Test func decodesAllFields() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let friend = try decoder.decode(Friend.self, from: Data(sampleJSON.utf8))

        #expect(friend.id == 42)
        #expect(friend.friendName == "Alice")
        #expect(friend.friendPhoneNumber == "+18015551234")
        #expect(friend.status == .accepted)
    }

    @Test func decodesUserId() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let friend = try decoder.decode(Friend.self, from: Data(sampleJSON.utf8))

        #expect(friend.userId == UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    }

    @Test func decodesPendingStatus() throws {
        let json = """
        {
            "id": 1,
            "user_id": "00000000-0000-0000-0000-000000000001",
            "friend_name": "Bob",
            "friend_phone_number": "+18015559999",
            "status": "pending",
            "invitation_timestamp": "2026-04-13T12:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let friend = try decoder.decode(Friend.self, from: Data(json.utf8))
        #expect(friend.status == .pending)
    }
}

// MARK: - FriendInsert Encoding

@Suite("FriendInsert Coding")
@MainActor
struct FriendInsertCodingTests {

    @Test func encodesSnakeCaseKeys() throws {
        let userId = UUID()
        let insert = FriendInsert(
            userId: userId,
            friendName: "Carol",
            friendPhoneNumber: "+18015550000"
        )
        let data = try JSONEncoder().encode(insert)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(dict["user_id"] != nil)
        #expect(dict["friend_name"] as? String == "Carol")
        #expect(dict["friend_phone_number"] as? String == "+18015550000")
        #expect(dict["userId"] == nil)
        #expect(dict["friendName"] == nil)
    }
}

// MARK: - Nudge Model Coding

@Suite("Nudge Coding")
@MainActor
struct NudgeCodingTests {

    private let sampleJSON = """
    {
        "id": 7,
        "friend_id": 42,
        "prompt": "You're doing great!",
        "friend_reply": "Thanks!",
        "type": "encouragement",
        "status": "replied",
        "sent_timestamp": "2026-04-13T14:00:00Z"
    }
    """

    @Test func decodesAllFields() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let nudge = try decoder.decode(Nudge.self, from: Data(sampleJSON.utf8))

        #expect(nudge.id == 7)
        #expect(nudge.friendId == 42)
        #expect(nudge.prompt == "You're doing great!")
        #expect(nudge.friendReply == "Thanks!")
        #expect(nudge.type == .encouragement)
        #expect(nudge.status == .replied)
    }

    @Test func decodesNilFriendReplyAndNilType() throws {
        // Before the friend replies, both friend_reply and type are null
        let json = """
        {
            "id": 8,
            "friend_id": 1,
            "prompt": "Josh has been on his phone for 2 hours!\\n\\nReply 1 for encouragement...",
            "friend_reply": null,
            "type": null,
            "status": "sent_to_friend",
            "sent_timestamp": "2026-04-13T14:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let nudge = try decoder.decode(Nudge.self, from: Data(json.utf8))
        #expect(nudge.friendReply == nil)
        #expect(nudge.type == nil)
        #expect(nudge.status == .sentToFriend)
    }

    @Test func decodesTypeAfterReply() throws {
        // After the friend replies, type is set to the resolved type
        let json = """
        {
            "id": 9,
            "friend_id": 1,
            "prompt": "Josh has been on his phone for 2 hours!\\n\\nReply 1 for encouragement...",
            "friend_reply": "You've got this! Time to take a break. 💪",
            "type": "encouragement",
            "status": "reply_delivered",
            "sent_timestamp": "2026-04-13T14:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let nudge = try decoder.decode(Nudge.self, from: Data(json.utf8))
        #expect(nudge.type == .encouragement)
        #expect(nudge.friendReply != nil)
    }
}

// MARK: - SocialViewModel Tests

@Suite("SocialViewModel")
@MainActor
struct SocialViewModelTests {

    private func makeFriend(id: Int, status: FriendStatus = .accepted) -> Friend {
        Friend(
            id: id,
            userId: UUID(),
            friendName: "Friend \(id)",
            friendPhoneNumber: "+18015550000",
            status: status,
            invitationTimestamp: Date()
        )
    }

    @Test func loadPopulatesFriends() async {
        let mock = MockFriendService()
        mock.friendsToReturn = [makeFriend(id: 1), makeFriend(id: 2)]
        let vm = SocialViewModel(friendService: mock)

        await vm.load(userId: UUID())

        #expect(vm.friends.count == 2)
        #expect(vm.isLoading == false)
        #expect(vm.error == nil)
    }

    @Test func loadSetsErrorOnFailure() async {
        let mock = MockFriendService()
        mock.errorToThrow = URLError(.notConnectedToInternet)
        let vm = SocialViewModel(friendService: mock)

        await vm.load(userId: UUID())

        #expect(vm.error != nil)
        #expect(vm.friends.isEmpty)
        #expect(vm.isLoading == false)
    }

    @Test func deleteFriendRemovesFromList() async {
        let friend = makeFriend(id: 5)
        let mock = MockFriendService()
        mock.friendsToReturn = [friend]
        let vm = SocialViewModel(friendService: mock)
        await vm.load(userId: UUID())

        await vm.deleteFriend(friend)

        #expect(vm.friends.isEmpty)
        #expect(mock.deletedIds.contains(5))
    }

    @Test func deleteErrorSetsError() async {
        let friend = makeFriend(id: 3)
        let mock = MockFriendService()
        mock.friendsToReturn = [friend]
        let vm = SocialViewModel(friendService: mock)
        await vm.load(userId: UUID())
        mock.errorToThrow = URLError(.notConnectedToInternet)

        await vm.deleteFriend(friend)

        #expect(vm.error != nil)
    }
}

// MARK: - Mock

private final class MockFriendService: FriendServiceProtocol {
    var friendsToReturn: [Friend] = []
    var errorToThrow: Error? = nil
    var deletedIds: [Int] = []

    func fetchFriends(userId: UUID) async throws -> [Friend] {
        if let error = errorToThrow { throw error }
        return friendsToReturn
    }

    func addFriend(userId: UUID, name: String, phoneNumber: String) async throws {
        if let error = errorToThrow { throw error }
    }

    func deleteFriend(id: Int) async throws {
        if let error = errorToThrow { throw error }
        deletedIds.append(id)
    }

    func updateFriendName(id: Int, name: String) async throws {
        if let error = errorToThrow { throw error }
    }

    func fetchNudgeHistory(friendId: Int) async throws -> [Nudge] {
        if let error = errorToThrow { throw error }
        return []
    }
}

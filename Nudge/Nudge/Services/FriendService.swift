import Foundation
import Supabase

// MARK: - Protocol

protocol FriendServiceProtocol {
    func fetchFriends(userId: UUID) async throws -> [Friend]
    func addFriend(userId: UUID, name: String, phoneNumber: String) async throws
    func deleteFriend(id: Int) async throws
    func updateFriendName(id: Int, name: String) async throws
    func fetchNudgeHistory(friendId: Int) async throws -> [Nudge]
    /// The friend a nudge was sent to, or nil if the nudge doesn't exist / isn't the user's (RLS).
    func fetchFriendId(forNudgeId nudgeId: Int) async throws -> Int?
}

// MARK: - Service

@MainActor
class FriendService: FriendServiceProtocol {

    func fetchFriends(userId: UUID) async throws -> [Friend] {
        try await supabase
            .from("friend")
            .select()
            .eq("user_id", value: userId)
            .neq("status", value: "blocked")
            .order("invitation_timestamp", ascending: false)
            .execute()
            .value
    }

    func addFriend(userId: UUID, name: String, phoneNumber: String) async throws {
        let insert = FriendInsert(
            userId: userId,
            friendName: name,
            friendPhoneNumber: phoneNumber
        )
        try await supabase
            .from("friend")
            .insert(insert)
            .execute()
    }

    func deleteFriend(id: Int) async throws {
        try await supabase
            .from("friend")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    func updateFriendName(id: Int, name: String) async throws {
        try await supabase
            .from("friend")
            .update(["friend_name": name])
            .eq("id", value: id)
            .execute()
    }

    func fetchNudgeHistory(friendId: Int) async throws -> [Nudge] {
        try await supabase
            .from("nudge")
            .select()
            .eq("friend_id", value: friendId)
            .order("sent_timestamp", ascending: false)
            .execute()
            .value
    }

    func fetchFriendId(forNudgeId nudgeId: Int) async throws -> Int? {
        struct NudgeFriendRow: Decodable {
            let friendId: Int
            enum CodingKeys: String, CodingKey {
                case friendId = "friend_id"
            }
        }

        // Array + limit instead of .single(): zero rows is a normal "not found", not an error.
        let rows: [NudgeFriendRow] = try await supabase
            .from("nudge")
            .select("friend_id")
            .eq("id", value: nudgeId)
            .limit(1)
            .execute()
            .value
        return rows.first?.friendId
    }
}

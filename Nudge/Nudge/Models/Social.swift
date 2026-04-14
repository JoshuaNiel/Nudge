import Foundation

// MARK: - Enums

enum FriendStatus: String, Codable {
    case pending
    case accepted
    case blocked
}

enum NudgeType: String, Codable {
    case shame
    case encouragement
    case custom
}

enum NudgeStatus: String, Codable {
    case sentToFriend    = "sent_to_friend"
    case replied
    case replyDelivered  = "reply_delivered"
    case failed
}

// MARK: - Friend

struct Friend: Codable, Identifiable {
    let id: Int
    let userId: UUID
    let friendName: String
    let friendPhoneNumber: String
    let status: FriendStatus
    let invitationTimestamp: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId               = "user_id"
        case friendName           = "friend_name"
        case friendPhoneNumber    = "friend_phone_number"
        case status
        case invitationTimestamp  = "invitation_timestamp"
    }
}

// MARK: - FriendInsert

struct FriendInsert: Encodable {
    let userId: UUID
    let friendName: String
    let friendPhoneNumber: String

    enum CodingKeys: String, CodingKey {
        case userId            = "user_id"
        case friendName        = "friend_name"
        case friendPhoneNumber = "friend_phone_number"
    }
}

// MARK: - Nudge

struct Nudge: Codable, Identifiable {
    let id: Int
    let friendId: Int
    let prompt: String        // Full SMS sent to friend (report + options)
    let friendReply: String?  // Resolved message delivered to app user (nil until friend replies)
    let type: NudgeType?      // Set when friend replies (nil while awaiting response)
    let status: NudgeStatus
    let sentTimestamp: Date

    enum CodingKeys: String, CodingKey {
        case id
        case friendId      = "friend_id"
        case prompt
        case friendReply   = "friend_reply"
        case type
        case status
        case sentTimestamp = "sent_timestamp"
    }
}

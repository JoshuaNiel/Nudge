import Foundation

// MARK: - DeviceToken

/// Helpers for APNs device tokens.
enum DeviceToken {
    /// Encodes the raw APNs token as the lowercase hex string APNs expects in
    /// `POST /3/device/<token>` (and that `device_tokens.token` stores).
    nonisolated static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - DeviceTokenInsert

/// Row upserted into `public.device_tokens` (unique on `user_id, token`).
///
/// `updatedAt` is sent explicitly so an upsert of an existing row refreshes it —
/// the column default only applies on insert.
struct DeviceTokenInsert: Encodable {
    let userId: UUID
    let token: String
    let platform: String
    let updatedAt: Date

    init(userId: UUID, token: String, platform: String = "apns", updatedAt: Date) {
        self.userId = userId
        self.token = token
        self.platform = platform
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case userId    = "user_id"
        case token
        case platform
        case updatedAt = "updated_at"
    }
}

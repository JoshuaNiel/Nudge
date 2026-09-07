import Foundation

// MARK: - Profile

struct Profile: Codable, Equatable {
    let userId: UUID
    let firstName: String?
    let lastName: String?
    let phoneNumber: String?
    let timeZone: String?
    let weekStart: Int

    enum CodingKeys: String, CodingKey {
        case userId      = "user_id"
        case firstName   = "first_name"
        case lastName    = "last_name"
        case phoneNumber = "phone_number"
        case timeZone    = "time_zone"
        case weekStart   = "week_start"
    }
}

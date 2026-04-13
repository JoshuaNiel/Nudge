import Foundation

// MARK: - Enums

enum GoalFrequency: String, Codable {
    case daily
    case weekly
    case monthly
}

enum GoalTargetType: String, Codable {
    case app
    case category
    case total
}

// MARK: - Goal

struct Goal: Codable, Identifiable {
    let id: Int
    let userId: UUID
    let limitSeconds: Int
    let frequency: GoalFrequency
    let targetType: GoalTargetType
    let bundleId: String?
    let categoryId: Int?
    let temporary: Bool
    let startDate: String?
    let endDate: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId       = "user_id"
        case limitSeconds = "limit_seconds"
        case frequency
        case targetType   = "target_type"
        case bundleId     = "bundle_id"
        case categoryId   = "category_id"
        case temporary
        case startDate    = "start_date"
        case endDate      = "end_date"
    }
}

// MARK: - AppCategory

struct AppCategory: Codable, Identifiable {
    let id: Int
    let userId: UUID
    let name: String
    let color: String   // hex "#RRGGBB"

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name
        case color
    }
}

// MARK: - AppCategoryMember

struct AppCategoryMember: Codable {
    let bundleId: String
    let categoryId: Int

    enum CodingKeys: String, CodingKey {
        case bundleId    = "bundle_id"
        case categoryId  = "category_id"
    }
}

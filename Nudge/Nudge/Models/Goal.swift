import Foundation

// `GoalFrequency` and `GoalTargetType` live in `Shared/GoalTypes.swift`: the monitor
// extension needs them for `GoalSummary`.

// MARK: - Goal

struct Goal: Codable, Identifiable {
    let id: Int
    let userId: UUID
    let limitSeconds: Int
    let frequency: GoalFrequency
    let targetType: GoalTargetType
    let bundleId: String?       // deprecated (migration 006) — never written
    let categoryId: Int?
    let temporary: Bool
    let startDate: String?
    let endDate: String?
    /// App goals: base64 PropertyList `FamilyActivitySelection` (see `SelectionCodec`).
    let selection: String?
    /// App goals: user-typed display name (tokens have no readable name).
    let label: String?

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
        case selection
        case label
    }
}

// MARK: - AppCategory

struct AppCategory: Codable, Identifiable {
    let id: Int
    let userId: UUID
    let name: String
    let color: String   // hex "#RRGGBB"
    /// Base64 PropertyList `FamilyActivitySelection` (≥1 token). `nil` for categories
    /// created before migration 006.
    let selection: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name
        case color
        case selection
    }
}

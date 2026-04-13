import Foundation
import Supabase

struct GoalInsert: Encodable {
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

class GoalService {

    func fetchGoals(userId: UUID) async throws -> [Goal] {
        try await supabase
            .from("goal")
            .select()
            .eq("user_id", value: userId)
            .execute()
            .value
    }

    func createGoal(_ goal: GoalInsert) async throws {
        try await supabase
            .from("goal")
            .insert(goal)
            .execute()
    }

    func deleteGoal(id: Int, userId: UUID) async throws {
        try await supabase
            .from("goal")
            .delete()
            .eq("id", value: id)
            .eq("user_id", value: userId)
            .execute()
    }
}

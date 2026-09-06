import Foundation
import Supabase

// MARK: - GoalWithDetails (private join model)

/// Decoded from a Supabase query that joins the `app` and `app_category` tables
/// to retrieve display names alongside goal data.
private struct GoalWithDetails: Decodable {
    let id: Int
    let limitSeconds: Int
    let frequency: GoalFrequency
    let targetType: GoalTargetType
    let bundleId: String?
    let categoryId: Int?
    let temporary: Bool
    let startDate: String?
    let endDate: String?
    let app: AppInfo?
    let appCategory: CategoryInfo?

    struct AppInfo: Decodable {
        let name: String
    }
    struct CategoryInfo: Decodable {
        let name: String
    }

    enum CodingKeys: String, CodingKey {
        case id
        case limitSeconds = "limit_seconds"
        case frequency
        case targetType   = "target_type"
        case bundleId     = "bundle_id"
        case categoryId   = "category_id"
        case temporary
        case startDate    = "start_date"
        case endDate      = "end_date"
        case app
        case appCategory  = "app_category"
    }

    func toGoalSummary() -> GoalSummary? {
        switch targetType {
        case .app:
            guard let bundleId else { return nil }
            let label = app?.name ?? bundleId.components(separatedBy: ".").last ?? bundleId
            return GoalSummary(
                goalId: id,
                eventName: "app.\(bundleId)",
                limitSeconds: limitSeconds,
                targetLabel: label,
                appBundleId: bundleId
            )
        case .category:
            guard let categoryId else { return nil }
            let label = appCategory?.name ?? "Category \(categoryId)"
            return GoalSummary(
                goalId: id,
                eventName: "category.\(categoryId)",
                limitSeconds: limitSeconds,
                targetLabel: label,
                appBundleId: nil
            )
        case .total:
            return GoalSummary(
                goalId: id,
                eventName: "total",
                limitSeconds: limitSeconds,
                targetLabel: "All Apps",
                appBundleId: nil
            )
        }
    }
}

// MARK: - GoalInsert

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

    /// Fetches all goals with their display names (app name or category name)
    /// and converts them to `GoalSummary` values for use by MonitoringRegistrationService.
    func fetchGoalSummaries(userId: UUID) async throws -> [GoalSummary] {
        let goals: [GoalWithDetails] = try await supabase
            .from("goal")
            .select("""
                id, limit_seconds, frequency, target_type, bundle_id, category_id, \
                temporary, start_date, end_date, \
                app(name), app_category(name)
                """)
            .eq("user_id", value: userId)
            .execute()
            .value

        return goals.compactMap { $0.toGoalSummary() }
    }
}

import Foundation
import Supabase
import os

// MARK: - GoalSummaryRow (monitoring join model)

/// One `goal` row with its category embedded (`app_category(name, selection)`), as
/// returned by `fetchGoalSummaries`. Internal rather than private so the mapping to
/// `GoalSummary` is unit-tested against literal PostgREST JSON.
struct GoalSummaryRow: Decodable {
    let id: Int
    let limitSeconds: Int
    let frequency: GoalFrequency
    let targetType: GoalTargetType
    let categoryId: Int?
    let selection: String?
    let label: String?
    let startDate: String?
    let endDate: String?
    let appCategory: CategoryInfo?

    struct CategoryInfo: Decodable {
        let name: String
        let selection: String?
    }

    enum CodingKeys: String, CodingKey {
        case id
        case limitSeconds = "limit_seconds"
        case frequency
        case targetType   = "target_type"
        case categoryId   = "category_id"
        case selection
        case label
        case startDate    = "start_date"
        case endDate      = "end_date"
        case appCategory  = "app_category"
    }

    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "GoalService")

    /// Labels (Phase 3 G2): app → `label`, category → category name, total → "All Apps".
    /// Selections: app → the goal's own, category → the category's, total → none.
    /// A missing or invalid selection yields `selectionData == nil`; the goal stays in the
    /// catalog (the UI shows "Re-select app") and `MonitoringPlan` skips it.
    func toGoalSummary() -> GoalSummary {
        let targetLabel: String
        let encodedSelection: String?
        switch targetType {
        case .app:
            targetLabel = label ?? "App"
            encodedSelection = selection
        case .category:
            targetLabel = appCategory?.name ?? "Category"
            encodedSelection = appCategory?.selection
        case .total:
            targetLabel = "All Apps"
            encodedSelection = nil
        }

        let selectionData = encodedSelection.flatMap { SelectionCodec.data(fromBase64: $0) }
        if encodedSelection != nil && selectionData == nil {
            Self.logger.error("goal \(id) has a selection that is not valid base64")
        }

        return GoalSummary(
            goalId: id,
            eventName: MonitoringPlan.goalEventBase(goalId: id),
            limitSeconds: limitSeconds,
            targetLabel: targetLabel,
            targetType: targetType,
            frequency: frequency,
            startDate: startDate,
            endDate: endDate,
            selectionData: selectionData
        )
    }
}

// MARK: - GoalInsert

struct GoalInsert: Encodable {
    let userId: UUID
    let limitSeconds: Int
    let frequency: GoalFrequency
    let targetType: GoalTargetType
    let categoryId: Int?
    let selection: String?
    let label: String?
    let temporary: Bool
    let startDate: String?
    let endDate: String?

    enum CodingKeys: String, CodingKey {
        case userId       = "user_id"
        case limitSeconds = "limit_seconds"
        case frequency
        case targetType   = "target_type"
        case categoryId   = "category_id"
        case selection
        case label
        case temporary
        case startDate    = "start_date"
        case endDate      = "end_date"
    }
}

// MARK: - Protocol

protocol GoalServiceProtocol {
    func fetchGoals(userId: UUID) async throws -> [Goal]
    func createGoal(_ goal: GoalInsert) async throws
    func deleteGoal(id: Int, userId: UUID) async throws
    func fetchGoalSummaries(userId: UUID) async throws -> [GoalSummary]
}

// MARK: - Service

@MainActor
class GoalService: GoalServiceProtocol {

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

    /// Fetches every goal (all frequencies, all dates — the catalog) with its label and
    /// token selection, converted to `GoalSummary` for `MonitoringRegistrationService`.
    /// Filtering to today's active set happens in `MonitoringPlan`.
    func fetchGoalSummaries(userId: UUID) async throws -> [GoalSummary] {
        let rows: [GoalSummaryRow] = try await supabase
            .from("goal")
            .select("""
                id, limit_seconds, frequency, target_type, category_id, \
                selection, label, start_date, end_date, \
                app_category(name, selection)
                """)
            .eq("user_id", value: userId)
            .execute()
            .value

        return rows.map { $0.toGoalSummary() }
    }
}

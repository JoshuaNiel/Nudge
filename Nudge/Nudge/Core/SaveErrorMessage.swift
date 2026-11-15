import Foundation
import Supabase

/// User-facing messages for failed goal/category writes. Raw database errors are never
/// shown: they leak schema details and mean nothing to the user.
enum SaveErrorMessage {

    /// Postgres SQLSTATE `unique_violation`.
    static let uniqueViolationCode = "23505"

    static let genericGoal = "Couldn't save the goal. Please try again."
    static let genericCategory = "Couldn't save the category. Please try again."

    static func isUniqueViolation(_ error: Error) -> Bool {
        (error as? PostgrestError)?.code == uniqueViolationCode
    }

    /// Duplicate non-temporary goal for the same target (ADR-010 partial unique indexes).
    static func goal(for error: Error) -> String {
        isUniqueViolation(error)
            ? "You already have a daily goal for this."
            : genericGoal
    }

    /// `app_category_unique_name` (user_id, name).
    static func category(for error: Error) -> String {
        isUniqueViolation(error)
            ? "You already have a category with this name."
            : genericCategory
    }
}

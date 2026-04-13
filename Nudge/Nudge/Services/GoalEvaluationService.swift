import Foundation
import Supabase

class GoalEvaluationService {

    /// Returns the number of seconds used toward the given goal in its current window.
    /// - Parameters:
    ///   - goal: The goal to evaluate.
    ///   - userId: The authenticated user's ID.
    ///   - timeZone: The user's local timezone (used to compute day/week/month boundaries).
    ///   - weekStart: Day-of-week the user considers the start of the week (0 = Sunday, 1 = Monday, …).
    func fetchUsedSeconds(
        goal: Goal,
        userId: UUID,
        timeZone: TimeZone,
        weekStart: Int
    ) async throws -> Int {
        // TODO: implement when Phase 1 usage data is available
        return 0
    }
}

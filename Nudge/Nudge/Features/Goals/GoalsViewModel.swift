import Foundation
import Combine

// MARK: - GoalWithProgress

struct GoalWithProgress: Identifiable {
    let goal: Goal
    let usedSeconds: Int

    var id: Int { goal.id }

    var progressFraction: Double {
        min(Double(usedSeconds) / Double(goal.limitSeconds), 1.0)
    }

    var isExceeded: Bool {
        usedSeconds >= goal.limitSeconds
    }
}

// MARK: - GoalsViewModel

class GoalsViewModel: ObservableObject {
    @Published var goals: [GoalWithProgress] = []
    @Published var isLoading = false
    @Published var error: String? = nil

    private let goalService = GoalService()
    private let evaluationService = GoalEvaluationService()

    func load(userId: UUID) async {
        error = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await goalService.fetchGoals(userId: userId)
            var results: [GoalWithProgress] = []
            for goal in fetched {
                let used = try await evaluationService.fetchUsedSeconds(
                    goal: goal,
                    userId: userId,
                    timeZone: .current,
                    weekStart: 0
                )
                results.append(GoalWithProgress(goal: goal, usedSeconds: used))
            }
            goals = results
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteGoal(_ goal: Goal, userId: UUID) async {
        do {
            try await goalService.deleteGoal(id: goal.id, userId: userId)
            goals.removeAll { $0.goal.id == goal.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

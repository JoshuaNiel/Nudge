import Foundation
import Combine
import FamilyControls

/// Goals list + detail state (Phase 3b).
///
/// Goals and categories come from Supabase; today's 10%-step progress comes from the App
/// Group (written by the monitor extension) and is re-read cheaply with `refreshProgress`
/// on appear and on foreground, without a network round trip.
///
/// Every successful write calls `monitoring.goalDidChange()` exactly once; failures
/// never do (G9).
@MainActor
final class GoalsViewModel: ObservableObject {
    @Published private(set) var items: [GoalListItem] = []
    @Published var isLoading = false
    /// Load failure: replaces the list with an error state.
    @Published var error: String? = nil
    /// Delete failure: shown as an alert over the (unchanged) list.
    @Published var actionError: String? = nil

    private var goals: [Goal] = []
    private var categories: [AppCategory] = []
    private var progress: [Int: Int] = [:]

    private let goalService: GoalServiceProtocol
    private let categoryService: CategoryServiceProtocol
    private let progressReader: GoalProgressReading
    private let monitoring: MonitoringRegistrationServiceProtocol
    private let now: () -> Date
    private let calendar: Calendar

    // Production init (ADR-028 two-init pattern).
    init() {
        self.goalService = GoalService()
        self.categoryService = CategoryService()
        self.progressReader = AppGroupGoalProgressReader()
        self.monitoring = MonitoringRegistrationService.shared
        self.now = Date.init
        self.calendar = .current
    }

    // Test init.
    init(
        goalService: GoalServiceProtocol,
        categoryService: CategoryServiceProtocol,
        progressReader: GoalProgressReading,
        monitoring: MonitoringRegistrationServiceProtocol,
        now: @escaping () -> Date,
        calendar: Calendar
    ) {
        self.goalService = goalService
        self.categoryService = categoryService
        self.progressReader = progressReader
        self.monitoring = monitoring
        self.now = now
        self.calendar = calendar
    }

    func item(id: Int) -> GoalListItem? {
        items.first { $0.id == id }
    }

    func category(id: Int) -> AppCategory? {
        categories.first { $0.id == id }
    }

    // MARK: - Loading

    func load(userId: UUID) async {
        error = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let fetchedGoals = try await goalService.fetchGoals(userId: userId)
            let fetchedCategories = try await categoryService.fetchCategories(userId: userId)
            goals = fetchedGoals.sorted { $0.id < $1.id }
            categories = fetchedCategories
            progress = progressReader.todayProgress()
            rebuildItems()
        } catch {
            goals = []
            categories = []
            items = []
            self.error = "Couldn't load your goals. Please try again."
        }
    }

    /// Re-reads today's milestones from the App Group (also picks up a day change).
    func refreshProgress() {
        progress = progressReader.todayProgress()
        rebuildItems()
    }

    // MARK: - Writes

    /// Returns whether the goal was deleted. Its progress entry is pruned later; the UI
    /// never looks up unknown ids.
    @discardableResult
    func deleteGoal(id: Int, userId: UUID) async -> Bool {
        actionError = nil
        do {
            try await goalService.deleteGoal(id: id, userId: userId)
        } catch {
            actionError = "Couldn't delete the goal. Please try again."
            return false
        }
        goals.removeAll { $0.id == id }
        rebuildItems()
        monitoring.goalDidChange()
        return true
    }

    /// Saves a new app selection for an app goal whose tokens no longer decode.
    /// Returns a user-facing error message, or `nil` on success.
    func reselectApp(goalId: Int, selection: FamilyActivitySelection, userId: UUID) async -> String? {
        if let message = GoalTargetValidation.appSelectionError(for: selection) { return message }
        guard let index = goals.firstIndex(where: { $0.id == goalId }) else { return "This goal no longer exists." }
        guard let encoded = SelectionCodec.encode(selection) else { return SaveErrorMessage.genericGoal }

        do {
            try await goalService.updateGoalSelection(id: goalId, userId: userId, selection: encoded)
        } catch {
            return SaveErrorMessage.goal(for: error)
        }
        goals[index] = goals[index].withSelection(encoded)
        rebuildItems()
        monitoring.goalDidChange()
        return nil
    }

    // MARK: - Private

    private func rebuildItems() {
        let today = MonitoringPlan.dayStamp(for: now(), calendar: calendar)
        items = goals.map { GoalListItem.make(goal: $0, categories: categories, progress: progress, today: today) }
    }
}

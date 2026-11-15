import Foundation
import Combine
import FamilyControls

/// Add Goal sheet state (Phase 3b): target (one app via `FamilyActivityPicker`, a
/// category, or total), a daily limit, and an optional temporary range. Daily only (G6):
/// there is no frequency choice.
@MainActor
final class AddGoalViewModel: ObservableObject {
    @Published var targetType: GoalTargetType = .app
    @Published var appSelection = FamilyActivitySelection()
    @Published var label = ""
    @Published private(set) var categories: [AppCategory] = []
    @Published var selectedCategoryId: Int? = nil
    @Published var hours = 1
    @Published var minutes = 0
    @Published var isTemporary = false
    @Published var startDate: Date
    @Published var endDate: Date

    @Published private(set) var isSaving = false
    @Published private(set) var isLoadingCategories = false
    @Published var errorMessage: String? = nil
    @Published private(set) var categoriesError: String? = nil

    private let goalService: GoalServiceProtocol
    private let categoryService: CategoryServiceProtocol
    private let monitoring: MonitoringRegistrationServiceProtocol
    private let now: () -> Date
    private let calendar: Calendar

    // Production init (ADR-028 two-init pattern).
    init() {
        self.goalService = GoalService()
        self.categoryService = CategoryService()
        self.monitoring = MonitoringRegistrationService.shared
        self.now = Date.init
        self.calendar = .current
        (self.startDate, self.endDate) = Self.defaultRange(now: Date(), calendar: .current)
    }

    // Test init.
    init(
        goalService: GoalServiceProtocol,
        categoryService: CategoryServiceProtocol,
        monitoring: MonitoringRegistrationServiceProtocol,
        now: @escaping () -> Date,
        calendar: Calendar
    ) {
        self.goalService = goalService
        self.categoryService = categoryService
        self.monitoring = monitoring
        self.now = now
        self.calendar = calendar
        (self.startDate, self.endDate) = Self.defaultRange(now: now(), calendar: calendar)
    }

    /// Today → one week later.
    private static func defaultRange(now: Date, calendar: Calendar) -> (Date, Date) {
        let start = calendar.startOfDay(for: now)
        return (start, calendar.date(byAdding: .day, value: 7, to: start) ?? start)
    }

    // MARK: - Validation

    /// The first problem blocking Save, in form order; `nil` when the goal can be saved.
    var validationError: String? {
        switch targetType {
        case .app:
            if let message = GoalTargetValidation.appSelectionError(for: appSelection) { return message }
            if let message = GoalTargetValidation.labelError(label) { return message }
        case .category:
            if selectedCategoryId == nil { return "Choose a category." }
        case .total:
            break
        }
        if let message = GoalLimit.error(hours: hours, minutes: minutes) { return message }
        if isTemporary, let message = GoalDateRange.error(start: startDate, end: endDate, today: now(), calendar: calendar) {
            return message
        }
        return nil
    }

    var canSave: Bool { validationError == nil && !isSaving }

    /// Earliest selectable start date in the picker.
    var today: Date { calendar.startOfDay(for: now()) }

    // MARK: - Categories

    func loadCategories(userId: UUID) async {
        categoriesError = nil
        isLoadingCategories = true
        defer { isLoadingCategories = false }
        do {
            categories = try await categoryService.fetchCategories(userId: userId).sortedByName()
        } catch {
            categoriesError = "Couldn't load your categories."
        }
    }

    /// "New category…" returned a saved category: show it and select it.
    func categoryCreated(_ category: AppCategory) {
        categories.removeAll { $0.id == category.id }
        categories.append(category)
        categories = categories.sortedByName()
        selectedCategoryId = category.id
    }

    // MARK: - Save

    /// Builds the row to insert, or `nil` if the form is invalid.
    func makeInsert(userId: UUID) -> GoalInsert? {
        guard validationError == nil else { return nil }

        var selection: String? = nil
        var goalLabel: String? = nil
        var categoryId: Int? = nil
        switch targetType {
        case .app:
            guard let encoded = SelectionCodec.encode(appSelection) else { return nil }
            selection = encoded
            goalLabel = GoalTargetValidation.normalizedLabel(label)
        case .category:
            categoryId = selectedCategoryId
        case .total:
            break
        }

        let days = isTemporary ? GoalDateRange.dayStrings(start: startDate, end: endDate, calendar: calendar) : nil
        return GoalInsert(
            userId: userId,
            limitSeconds: GoalLimit.seconds(hours: hours, minutes: minutes),
            frequency: .daily,
            targetType: targetType,
            categoryId: categoryId,
            selection: selection,
            label: goalLabel,
            temporary: isTemporary,
            startDate: days?.start,
            endDate: days?.end
        )
    }

    /// Returns whether the goal was created.
    func save(userId: UUID) async -> Bool {
        guard !isSaving else { return false }
        if let message = validationError {
            errorMessage = message
            return false
        }
        guard let insert = makeInsert(userId: userId) else {
            errorMessage = SaveErrorMessage.genericGoal
            return false
        }

        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try await goalService.createGoal(insert)
        } catch {
            errorMessage = SaveErrorMessage.goal(for: error)
            return false
        }
        monitoring.goalDidChange()
        return true
    }
}

extension Array where Element == AppCategory {
    /// Case-insensitive, locale-aware name order used by every category list.
    func sortedByName() -> [AppCategory] {
        sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

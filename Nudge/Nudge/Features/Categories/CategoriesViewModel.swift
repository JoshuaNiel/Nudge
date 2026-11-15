import Foundation
import Combine

/// Categories tab list (G10). Create/edit happen in `CategoryEditorViewModel`, which
/// reports the saved row back through `categorySaved`.
@MainActor
final class CategoriesViewModel: ObservableObject {
    @Published private(set) var categories: [AppCategory] = []
    @Published var isLoading = false
    @Published var error: String? = nil
    @Published var actionError: String? = nil

    private let categoryService: CategoryServiceProtocol
    private let monitoring: MonitoringRegistrationServiceProtocol

    // Production init (ADR-028 two-init pattern).
    init() {
        self.categoryService = CategoryService()
        self.monitoring = MonitoringRegistrationService.shared
    }

    // Test init.
    init(categoryService: CategoryServiceProtocol, monitoring: MonitoringRegistrationServiceProtocol) {
        self.categoryService = categoryService
        self.monitoring = monitoring
    }

    func load(userId: UUID) async {
        error = nil
        isLoading = true
        defer { isLoading = false }
        do {
            categories = try await categoryService.fetchCategories(userId: userId).sortedByName()
        } catch {
            categories = []
            self.error = "Couldn't load your categories. Please try again."
        }
    }

    /// Deletes the category; the DB cascades to its goals. Returns whether it succeeded.
    @discardableResult
    func delete(id: Int, userId: UUID) async -> Bool {
        actionError = nil
        do {
            try await categoryService.deleteCategory(id: id, userId: userId)
        } catch {
            actionError = "Couldn't delete the category. Please try again."
            return false
        }
        categories.removeAll { $0.id == id }
        monitoring.goalDidChange()
        return true
    }

    /// The editor saved a category (it already called `goalDidChange`).
    func categorySaved(_ category: AppCategory) {
        categories.removeAll { $0.id == category.id }
        categories.append(category)
        categories = categories.sortedByName()
    }
}

import Foundation
import Combine
import FamilyControls

/// Create/edit sheet for a category (G10): name, preset color, picker selection.
@MainActor
final class CategoryEditorViewModel: ObservableObject {
    enum Mode {
        case create
        case edit(AppCategory)
    }

    @Published var name: String
    @Published var color: String
    @Published var selection: FamilyActivitySelection
    @Published private(set) var isSaving = false
    @Published var errorMessage: String? = nil

    let mode: Mode
    /// Editing a category whose stored tokens no longer decode: the picker starts empty
    /// and the user must choose again.
    let selectionNeedsReselect: Bool

    private let categoryService: CategoryServiceProtocol
    private let monitoring: MonitoringRegistrationServiceProtocol

    // Production init (ADR-028 two-init pattern).
    convenience init(mode: Mode) {
        self.init(mode: mode, categoryService: CategoryService(), monitoring: MonitoringRegistrationService.shared)
    }

    // Test init.
    init(mode: Mode, categoryService: CategoryServiceProtocol, monitoring: MonitoringRegistrationServiceProtocol) {
        self.mode = mode
        self.categoryService = categoryService
        self.monitoring = monitoring
        switch mode {
        case .create:
            name = ""
            color = CategoryPalette.defaultColor
            selection = FamilyActivitySelection()
            selectionNeedsReselect = false
        case .edit(let category):
            name = category.name
            color = category.color
            let decoded = category.selection.flatMap(SelectionCodec.decode)
            selection = decoded ?? FamilyActivitySelection()
            selectionNeedsReselect = decoded.map(SelectionCodec.isEmpty) ?? true
        }
    }

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var validationError: String? {
        if let message = CategoryRules.nameError(name) { return message }
        if !CategoryPalette.isValidHex(color) { return "Choose a color." }
        return CategoryRules.selectionError(for: selection)
    }

    var canSave: Bool { validationError == nil && !isSaving }

    var summaryText: String { CategoryRules.summaryText(for: selection) }

    /// Returns the saved category, or `nil` on failure (with `errorMessage` set).
    func save(userId: UUID) async -> AppCategory? {
        guard !isSaving else { return nil }
        if let message = validationError {
            errorMessage = message
            return nil
        }
        guard let encoded = SelectionCodec.encode(selection) else {
            errorMessage = SaveErrorMessage.genericCategory
            return nil
        }

        let trimmedName = CategoryRules.normalizedName(name)
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }

        let saved: AppCategory
        do {
            switch mode {
            case .create:
                saved = try await categoryService.createCategory(userId: userId, name: trimmedName, color: color, selection: encoded)
            case .edit(let existing):
                saved = try await categoryService.updateCategory(
                    id: existing.id, userId: userId, name: trimmedName, color: color, selection: encoded
                )
            }
        } catch {
            errorMessage = SaveErrorMessage.category(for: error)
            return nil
        }
        // A selection edit changes what category goals monitor (signature includes the
        // selection fingerprint), so re-register.
        monitoring.goalDidChange()
        return saved
    }
}

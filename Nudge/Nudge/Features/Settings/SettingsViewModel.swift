import Foundation
import Combine
import Supabase

@MainActor
class SettingsViewModel: ObservableObject {
    @Published var firstName: String = ""
    @Published var lastName: String = ""
    @Published var phoneNumber: String = ""
    @Published var email: String = ""

    @Published var isLoading: Bool = false
    @Published var isSaving: Bool = false
    @Published var errorMessage: String? = nil
    @Published var didSave: Bool = false

    private let profileService: ProfileServiceProtocol

    // Captured originals from the last load/save, used for dirty-state tracking.
    private var originalFirstName: String = ""
    private var originalLastName: String = ""
    private var originalPhoneNumber: String = ""

    // Production init — uses real service
    init() {
        self.profileService = ProfileService()
    }

    // Test init — accepts a mock
    init(profileService: ProfileServiceProtocol) {
        self.profileService = profileService
    }

    // MARK: - Computed

    /// A phone number is acceptable when it is blank (opted out) or valid E.164.
    var isPhoneValid: Bool {
        let trimmed = phoneNumber.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.isValidE164
    }

    var firstNameError: String? {
        firstName.trimmingCharacters(in: .whitespaces).isEmpty ? "First name is required." : nil
    }

    var lastNameError: String? {
        lastName.trimmingCharacters(in: .whitespaces).isEmpty ? "Last name is required." : nil
    }

    var phoneError: String? {
        phoneNumber.e164ValidationError
    }

    /// True if any field's trimmed value differs from the captured (trimmed) original.
    var hasChanges: Bool {
        firstName.trimmingCharacters(in: .whitespaces) != originalFirstName.trimmingCharacters(in: .whitespaces)
            || lastName.trimmingCharacters(in: .whitespaces) != originalLastName.trimmingCharacters(in: .whitespaces)
            || phoneNumber.trimmingCharacters(in: .whitespaces) != originalPhoneNumber.trimmingCharacters(in: .whitespaces)
    }

    var canSave: Bool {
        hasChanges && firstNameError == nil && lastNameError == nil && phoneError == nil && !isSaving
    }

    // MARK: - Actions

    func load(userId: UUID, email: String) async {
        self.email = email
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let profile = try await profileService.fetchProfile(userId: userId)
            firstName = profile.firstName ?? ""
            lastName = profile.lastName ?? ""
            phoneNumber = profile.phoneNumber ?? ""
            captureOriginals()
        } catch {
            errorMessage = "Couldn't load your profile. Please try again."
        }
    }

    func save(userId: UUID) async {
        // Defensive: the Save button is disabled unless these are all nil.
        if let fieldError = firstNameError ?? lastNameError ?? phoneError {
            errorMessage = fieldError
            return
        }

        didSave = false
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }

        let trimmedFirstName = firstName.trimmingCharacters(in: .whitespaces)
        let trimmedLastName = lastName.trimmingCharacters(in: .whitespaces)
        let trimmedPhone = phoneNumber.trimmingCharacters(in: .whitespaces)
        let phoneToSave = trimmedPhone.isEmpty ? nil : trimmedPhone

        do {
            try await profileService.updateProfile(
                userId: userId,
                firstName: trimmedFirstName,
                lastName: trimmedLastName,
                phoneNumber: phoneToSave
            )
            // Reflect the just-saved values so `hasChanges` becomes false.
            originalFirstName = trimmedFirstName
            originalLastName = trimmedLastName
            originalPhoneNumber = trimmedPhone
            errorMessage = nil
            didSave = true
            // Auto-fade the confirmation after a short delay.
            Task {
                try? await Task.sleep(for: .seconds(2))
                didSave = false
            }
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
        }
    }

    private func captureOriginals() {
        originalFirstName = firstName
        originalLastName = lastName
        originalPhoneNumber = phoneNumber
    }

    // MARK: - Error mapping

    private static func userFacingMessage(for error: Error) -> String {
        // Postgres unique-violation on profile.phone_number (SQLSTATE 23505).
        if let pgError = error as? PostgrestError,
           pgError.code == "23505" || (pgError.message.contains("phone_number") && pgError.message.lowercased().contains("duplicate")) {
            return "That phone number is already in use by another account."
        }
        return "Couldn't save your profile. Please try again."
    }
}

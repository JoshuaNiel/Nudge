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

    var canSave: Bool {
        isPhoneValid && !isSaving
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
        } catch {
            errorMessage = "Couldn't load your profile. Please try again."
        }
    }

    func save(userId: UUID) async {
        guard isPhoneValid else {
            errorMessage = "Enter a valid phone number, e.g. +18015551234."
            return
        }

        didSave = false
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }

        let trimmedPhone = phoneNumber.trimmingCharacters(in: .whitespaces)
        let phoneToSave = trimmedPhone.isEmpty ? nil : trimmedPhone

        do {
            try await profileService.updateProfile(
                userId: userId,
                firstName: firstName.trimmingCharacters(in: .whitespaces),
                lastName: lastName.trimmingCharacters(in: .whitespaces),
                phoneNumber: phoneToSave
            )
            didSave = true
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
        }
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

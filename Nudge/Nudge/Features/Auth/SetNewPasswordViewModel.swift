import Foundation
import Combine

/// Drives the "Set new password" sheet shown after a recovery link signs the user in.
@MainActor
final class SetNewPasswordViewModel: ObservableObject {

    @Published var newPassword = ""
    @Published var confirmPassword = ""
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String? = nil
    @Published private(set) var didSucceed = false

    private let service: AuthRecoveryServiceProtocol

    // Production init — uses the real service
    init() {
        self.service = AuthService()
    }

    // Test init — accepts a mock
    init(service: AuthRecoveryServiceProtocol) {
        self.service = service
    }

    // MARK: - Computed

    var canSubmit: Bool {
        !isSaving && !newPassword.isEmpty && !confirmPassword.isEmpty
    }

    // MARK: - Actions

    func save() async {
        errorMessage = nil
        if let error = PasswordRules.validationError(password: newPassword, confirmation: confirmPassword) {
            errorMessage = error
            return
        }

        isSaving = true
        defer { isSaving = false }
        do {
            try await service.updatePassword(newPassword)
            didSucceed = true
            // Don't keep the plaintext around once it has been accepted.
            newPassword = ""
            confirmPassword = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

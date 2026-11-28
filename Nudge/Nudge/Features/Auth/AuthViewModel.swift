import Foundation
import Combine
import AuthenticationServices

/// Drives the sign-in / sign-up form on `AuthView`.
///
/// Sign-up applies `PasswordRules` (8+ characters, must match). Sign-in has no
/// length check, because existing accounts may have shorter passwords. A sign-up that
/// awaits email confirmation, or a sign-in refused with `email_not_confirmed`, hands
/// off to the confirm-email screen (`ConfirmEmailViewModel`), which owns Resend.
@MainActor
final class AuthViewModel: ObservableObject {

    enum Mode { case signIn, signUp }

    /// What a submit led to; `AuthView` routes on it.
    enum SubmitOutcome: Equatable {
        case signedIn
        /// Show the confirm-email screen with these credentials.
        case needsEmailConfirmation(PendingEmailConfirmation)
        /// Stay on the form; `errorMessage` says why.
        case failed
    }

    static let missingFieldsMessage = "Please fill in all fields."

    @Published var mode: Mode = .signIn
    @Published var email: String
    @Published var password = ""
    @Published var confirmPassword = ""
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String? = nil

    private let service: AuthEmailServiceProtocol

    // Production init — uses the real service
    init(prefillEmail: String = "") {
        self.service = AuthService()
        self.email = prefillEmail
    }

    // Test init — accepts a mock
    init(service: AuthEmailServiceProtocol, prefillEmail: String = "") {
        self.service = service
        self.email = prefillEmail
    }

    // MARK: - Email/Password

    /// Signs in or signs up.
    func submit() async -> SubmitOutcome {
        errorMessage = nil
        if let error = validationError() {
            errorMessage = error
            return .failed
        }

        isLoading = true
        defer { isLoading = false }
        do {
            switch mode {
            case .signIn:
                try await service.signIn(email: email, password: password)
            case .signUp:
                if try await service.signUp(email: email, password: password) {
                    // No session yet. The nudge://auth-callback link signs the
                    // user in; RootView moves on when it does.
                    return .needsEmailConfirmation(pendingConfirmation(.afterSignUp))
                }
            }
            return .signedIn
        } catch {
            return handle(error)
        }
    }

    // MARK: - Sign in with Apple

    /// Returns `true` when a session now exists.
    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async -> Bool {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            try await service.signInWithApple(credential: credential)
            return true
        } catch {
            errorMessage = AuthErrorMapping.message(for: error)
            return false
        }
    }

    func appleAuthorizationFailed(_ error: Error) {
        // ASAuthorizationError.canceled is not a real error — user dismissed the sheet
        if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Mode

    func toggleMode() {
        mode = mode == .signIn ? .signUp : .signIn
        errorMessage = nil
        password = ""
        confirmPassword = ""
    }

    // MARK: - Helpers

    private func validationError() -> String? {
        guard !email.isEmpty, !password.isEmpty else { return Self.missingFieldsMessage }
        if mode == .signUp {
            return PasswordRules.validationError(password: password, confirmation: confirmPassword)
        }
        return nil
    }

    private func handle(_ error: Error) -> SubmitOutcome {
        if mode == .signIn, AuthErrorMapping.isEmailNotConfirmed(error) {
            return .needsEmailConfirmation(pendingConfirmation(.unconfirmedSignIn))
        }
        if mode == .signUp, let weakPassword = AuthErrorMapping.weakPasswordMessage(for: error) {
            errorMessage = weakPassword
        } else {
            errorMessage = AuthErrorMapping.message(for: error)
        }
        return .failed
    }

    private func pendingConfirmation(_ variant: ConfirmEmailVariant) -> PendingEmailConfirmation {
        PendingEmailConfirmation(email: email, password: password, variant: variant)
    }
}

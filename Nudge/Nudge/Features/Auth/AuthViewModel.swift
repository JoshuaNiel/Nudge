import Foundation
import Combine
import AuthenticationServices

/// Drives the sign-in / sign-up form on `AuthView`.
///
/// Sign-up applies `PasswordRules` (8+ characters, must match). Sign-in has no
/// length check, because existing accounts may have shorter passwords. Signing in
/// before confirming the email offers a "Resend email" action.
@MainActor
final class AuthViewModel: ObservableObject {

    enum Mode { case signIn, signUp }

    enum ResendStatus: Equatable {
        case idle
        case sending
        case sent
        case failed(String)
    }

    static let missingFieldsMessage = "Please fill in all fields."
    static let passwordHint = "Use at least \(PasswordRules.minimumLength) characters."
    static let emailNotConfirmedMessage = "Confirm your email first. Check your inbox for the link."
    static let resendSentMessage = "Email sent. Check your inbox for the new link."

    @Published var mode: Mode = .signIn
    @Published var email = ""
    @Published var password = ""
    @Published var confirmPassword = ""
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String? = nil
    /// Set after sign-up when Supabase requires email confirmation before a session exists.
    @Published private(set) var confirmationSentTo: String? = nil
    /// The address a sign-in was refused for because it isn't confirmed; Resend uses it.
    @Published private(set) var unconfirmedEmail: String? = nil
    @Published private(set) var resendStatus: ResendStatus = .idle

    private let service: AuthEmailServiceProtocol

    // Production init — uses the real service
    init() {
        self.service = AuthService()
    }

    // Test init — accepts a mock
    init(service: AuthEmailServiceProtocol) {
        self.service = service
    }

    // MARK: - Computed

    var canResendConfirmation: Bool {
        unconfirmedEmail != nil && resendStatus != .sending
    }

    var resendMessage: String? {
        switch resendStatus {
        case .idle, .sending: nil
        case .sent: Self.resendSentMessage
        case .failed(let message): message
        }
    }

    // MARK: - Email/Password

    /// Signs in or signs up. Returns `true` when a session now exists.
    func submit() async -> Bool {
        resetMessages()
        if let error = validationError() {
            errorMessage = error
            return false
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
                    // user in; OnboardingCoordinator advances when it does.
                    confirmationSentTo = email
                    return false
                }
            }
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func resendConfirmation() async {
        guard let unconfirmedEmail, resendStatus != .sending else { return }
        resendStatus = .sending
        do {
            try await service.resendSignupConfirmation(email: unconfirmedEmail)
            resendStatus = .sent
        } catch {
            resendStatus = .failed(
                AuthErrorMapping.isRateLimited(error)
                    ? AuthError.rateLimited.localizedDescription
                    : error.localizedDescription
            )
        }
    }

    // MARK: - Sign in with Apple

    /// Returns `true` when a session now exists.
    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async -> Bool {
        resetMessages()
        isLoading = true
        defer { isLoading = false }
        do {
            try await service.signInWithApple(credential: credential)
            return true
        } catch {
            errorMessage = error.localizedDescription
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
        resetMessages()
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

    private func handle(_ error: Error) {
        switch mode {
        case .signIn where AuthErrorMapping.isEmailNotConfirmed(error):
            errorMessage = Self.emailNotConfirmedMessage
            unconfirmedEmail = email
        case .signUp:
            errorMessage = AuthErrorMapping.weakPasswordMessage(for: error) ?? error.localizedDescription
        default:
            errorMessage = error.localizedDescription
        }
    }

    private func resetMessages() {
        errorMessage = nil
        confirmationSentTo = nil
        unconfirmedEmail = nil
        resendStatus = .idle
    }
}

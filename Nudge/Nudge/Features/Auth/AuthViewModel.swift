import Foundation
import Combine
import AuthenticationServices

/// Drives the sign-in / sign-up form on `AuthView`.
///
/// Sign-up applies `PasswordRules` (8+ characters, must match). Sign-in has no
/// length check, because existing accounts may have shorter passwords. Signing in
/// before confirming the email offers a "Resend email" action, which repeats the
/// sign-up with the credentials that were refused (PKCE link, unlike `auth.resend`).
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
    static let resendFailedMessage = "Couldn't send the email. Try again."

    @Published var mode: Mode = .signIn
    @Published var email = "" {
        didSet { if email != oldValue { discardCapturedCredentials() } }
    }
    @Published var password = ""
    @Published var confirmPassword = ""
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String? = nil
    /// Set after sign-up when Supabase requires email confirmation before a session exists.
    @Published private(set) var confirmationSentTo: String? = nil
    /// The address a sign-in was refused for because it isn't confirmed; Resend uses it.
    @Published private(set) var unconfirmedEmail: String? = nil
    @Published private(set) var resendStatus: ResendStatus = .idle
    /// The password of the refused sign-in, so Resend can repeat the sign-up.
    /// Memory only; never logged or persisted. Cleared on a successful resend,
    /// when the email changes, and when the sign-in screen goes away.
    private var unconfirmedPassword: String? = nil

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
        unconfirmedEmail != nil && unconfirmedPassword != nil && resendStatus != .sending
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

    /// Repeats the sign-up with the captured credentials, so the new link uses PKCE.
    /// Returns `true` when a session now exists (the email was confirmed meanwhile).
    func resendConfirmation() async -> Bool {
        guard let unconfirmedEmail, let unconfirmedPassword, resendStatus != .sending else { return false }
        resendStatus = .sending
        do {
            let confirmationPending = try await service.signUp(email: unconfirmedEmail, password: unconfirmedPassword)
            self.unconfirmedPassword = nil
            guard confirmationPending else {
                resetMessages()
                return true
            }
            resendStatus = .sent
        } catch {
            resendStatus = .failed(
                AuthErrorMapping.isRateLimited(error)
                    ? AuthError.rateLimited.localizedDescription
                    : Self.resendFailedMessage
            )
        }
        return false
    }

    /// Drops the Resend credentials. Call when leaving the sign-in screen.
    func discardCapturedCredentials() {
        unconfirmedEmail = nil
        unconfirmedPassword = nil
        resendStatus = .idle
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
            unconfirmedPassword = password
        case .signUp:
            errorMessage = AuthErrorMapping.weakPasswordMessage(for: error) ?? error.localizedDescription
        default:
            errorMessage = error.localizedDescription
        }
    }

    private func resetMessages() {
        errorMessage = nil
        confirmationSentTo = nil
        discardCapturedCredentials()
    }
}

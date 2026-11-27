import Foundation
import Supabase
import AuthenticationServices

// MARK: - Protocol

/// The password-recovery and email-link surface of `AuthService`, split out so the
/// recovery ViewModels and `AuthRecoveryCoordinator` can be tested with a mock.
protocol AuthRecoveryServiceProtocol {
    /// Asks Supabase to email a reset link that redirects to `nudge://reset-password`.
    /// Throws `AuthError.rateLimited` when Supabase refuses for rate-limit reasons.
    func sendPasswordReset(email: String) async throws

    /// Exchanges the PKCE code in an auth email redirect for a session.
    /// Throws if the link is expired, already used, or was requested on another device.
    func establishSession(from url: URL) async throws

    /// Sets a new password for the currently signed-in (recovery) session.
    func updatePassword(_ newPassword: String) async throws
}

/// The email/password and Sign in with Apple surface of `AuthService`, split out so
/// `AuthViewModel` can be tested with a mock.
protocol AuthEmailServiceProtocol {
    func signIn(email: String, password: String) async throws

    /// Returns `true` when Supabase requires email confirmation before a session exists.
    /// Also used to resend the confirmation email (a repeat sign-up), because it
    /// sends a PKCE challenge and `auth.resend` doesn't.
    func signUp(email: String, password: String) async throws -> Bool

    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async throws
}

// MARK: - Service

@MainActor
class AuthService: AuthRecoveryServiceProtocol, AuthEmailServiceProtocol {

    // MARK: - Email/Password

    /// Creates the account. Returns `true` when Supabase requires the user to
    /// confirm their email before a session exists (email confirmation enabled);
    /// the confirmation link then lands on `nudge://auth-callback`.
    @discardableResult
    func signUp(email: String, password: String) async throws -> Bool {
        let response = try await supabase.auth.signUp(
            email: email,
            password: password,
            redirectTo: AuthDeepLink.emailConfirmation.redirectURL
        )
        return response.session == nil
    }

    func signIn(email: String, password: String) async throws {
        try await supabase.auth.signIn(email: email, password: password)
    }

    func signOut() async throws {
        try await supabase.auth.signOut()
    }

    // MARK: - Password recovery

    func sendPasswordReset(email: String) async throws {
        do {
            try await supabase.auth.resetPasswordForEmail(
                email,
                redirectTo: AuthDeepLink.passwordRecovery.redirectURL
            )
        } catch {
            if AuthErrorMapping.isRateLimited(error) { throw AuthError.rateLimited }
            throw error
        }
    }

    func establishSession(from url: URL) async throws {
        try await supabase.auth.session(from: url)
    }

    func updatePassword(_ newPassword: String) async throws {
        try await supabase.auth.update(user: UserAttributes(password: newPassword))
    }

    // MARK: - Sign in with Apple

    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async throws {
        guard let identityTokenData = credential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8) else {
            throw AuthError.missingAppleIdentityToken
        }

        try await supabase.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: identityToken)
        )
    }

    // MARK: - Profile

    /// Patches the auto-created profiles row with the user's name.
    func updateProfile(firstName: String, lastName: String) async throws {
        guard let userId = supabase.auth.currentUser?.id else {
            throw AuthError.notAuthenticated
        }

        try await supabase
            .from("profile")
            .update(["first_name": firstName, "last_name": lastName])
            .eq("user_id", value: userId)
            .execute()
    }

    // MARK: - Session

    func currentUser() -> User? {
        supabase.auth.currentUser
    }
}

// MARK: - Errors

enum AuthError: LocalizedError {
    case missingAppleIdentityToken
    case notAuthenticated
    /// Supabase refused an email-sending request because of rate limiting.
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .missingAppleIdentityToken:
            return "Could not retrieve Apple identity token."
        case .notAuthenticated:
            return "No authenticated user found."
        case .rateLimited:
            return "Please wait a minute before trying again."
        }
    }
}

// MARK: - Rate limiting

/// Classifies a Supabase Auth failure as a rate limit from its primitive parts,
/// so the rule is testable without constructing SDK error types.
enum AuthRateLimit {
    private static let rateLimitCodes: Set<String> = [
        "over_email_send_rate_limit",
        "over_request_rate_limit",
    ]

    static func isRateLimited(errorCode: String?, httpStatus: Int?) -> Bool {
        if httpStatus == 429 { return true }
        guard let errorCode else { return false }
        return rateLimitCodes.contains(errorCode)
    }
}

import Foundation
import Supabase
internal import Auth  // for `Auth.AuthError` (shadowed by the app's `AuthError`)

/// Reads Supabase Auth SDK errors (supabase-swift 2.43.1) for the auth screens.
/// Kept apart from the ViewModels so they never match on SDK error cases themselves.
enum AuthErrorMapping {

    /// Shown for every rate limit in the auth flows (reset request, sign-in, sign-up,
    /// Resend, Set New Password). Spec C5: one generic message, no wait time promised.
    static let busyMessage = "Our servers are busy right now. Please try again in a moment."

    /// `busyMessage` for a rate limit, otherwise `nil`.
    static func rateLimitMessage(for error: Error) -> String? {
        isRateLimited(error) ? busyMessage : nil
    }

    /// What an auth screen shows for a failure with no screen-specific mapping:
    /// the busy message for a rate limit, otherwise the error's own description.
    static func message(for error: Error) -> String {
        rateLimitMessage(for: error) ?? error.localizedDescription
    }

    /// Sign-in with a correct password for an account whose email isn't confirmed yet.
    /// GoTrue returns 400 `email_not_confirmed` only after the password checks out.
    static func isEmailNotConfirmed(_ error: Error) -> Bool {
        guard let authError = error as? Auth.AuthError else { return false }
        return authError.errorCode == .emailNotConfirmed
    }

    /// Rate limit from Supabase (`over_email_send_rate_limit`, `over_request_rate_limit`,
    /// or HTTP 429), or the app's own `AuthError.rateLimited`.
    static func isRateLimited(_ error: Error) -> Bool {
        if let appError = error as? AuthError, case .rateLimited = appError { return true }
        guard let authError = error as? Auth.AuthError,
              case let .api(_, errorCode, _, response) = authError else { return false }
        return AuthRateLimit.isRateLimited(errorCode: errorCode.rawValue, httpStatus: response.statusCode)
    }

    /// What to show when the server rejects a new password as weak, or `nil` for other errors.
    ///
    /// The SDK turns every `weak_password` response into `.weakPassword(message:reasons:)`.
    /// `reasons` are machine codes (`length`, `characters`, `pwned`); `message` is the
    /// server's human-readable sentence for them, so that is what the user sees. With no
    /// reasons (or no usable message) the app's own length rule is the best explanation.
    static func weakPasswordMessage(for error: Error) -> String? {
        guard let authError = error as? Auth.AuthError,
              case let .weakPassword(message, reasons) = authError else { return nil }
        let serverMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Unknown" is the SDK's placeholder when the response had no message.
        if !reasons.isEmpty, !serverMessage.isEmpty, serverMessage != "Unknown" {
            return serverMessage
        }
        return PasswordRules.tooShortMessage
    }
}

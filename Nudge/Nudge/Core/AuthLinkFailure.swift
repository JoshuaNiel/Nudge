import Foundation
import Supabase
internal import Auth  // for `Auth.AuthError` (shadowed by the app's `AuthError`)

/// Why an auth email link couldn't sign the user in, and what to tell them.
///
/// Pure: classification looks only at the redirect URL and the error that
/// `supabase.auth.session(from:)` threw. Verified against supabase-swift 2.43.1
/// and the Supabase Auth (GoTrue) server source:
/// - `/verify` failures redirect with `error` / `error_code` / `error_description`
///   (PKCE puts them in the query *and* the fragment).
/// - With no stored code verifier the SDK doesn't throw on its own. It sends
///   `code_verifier: null`, and the server's PKCE grant rejects that with
///   `validation_failed` (the only `validation_failed` that grant returns once a
///   code is present).
/// - A verifier from a newer request gives `bad_code_verifier`; a consumed flow
///   state gives `flow_state_not_found`; a stale one gives `flow_state_expired`.
/// Anything unconfirmed falls back to `.expired`.
enum AuthLinkFailure: String, Equatable, CaseIterable {
    case expired
    case differentDevice
    case olderRequest
    case alreadyUsed
    case malformed
    case offline
    /// A confirmation link that confirmed the email but carries no PKCE code: the
    /// implicit-flow link a resent confirmation email produces (SDK 2.43.1's
    /// `resend` sends no code challenge). The tokens in it are deliberately unused.
    case signInRequired

    static let alertTitle = "Link Problem"

    static let expiredMessage = "This link has expired. Request a new one."
    static let differentDeviceResetMessage = "This link was requested on a different device. Open it on the iPhone where you asked for it, or request a new one here."
    static let confirmedSignInMessage = "Your email is confirmed. Sign in with your email and password."
    static let olderRequestMessage = "This link is from an older request. Use the newest email, or request a new one."
    static let alreadyUsedMessage = "This link has already been used. Request a new one if you still need it."
    static let malformedMessage = "This link isn't valid. Request a new one."
    static let offlineMessage = "Couldn't check the link. Check your connection and try again."

    // MARK: - Messages

    func message(for link: AuthDeepLink) -> String {
        switch self {
        case .expired: Self.expiredMessage
        case .differentDevice:
            // GoTrue confirms the email in /verify before redirecting, so a
            // confirmation link opened elsewhere has still confirmed the account.
            // (Spec C2 assumption, to confirm on device.)
            link == .emailConfirmation ? Self.confirmedSignInMessage : Self.differentDeviceResetMessage
        case .olderRequest: Self.olderRequestMessage
        case .alreadyUsed: Self.alreadyUsedMessage
        case .malformed: Self.malformedMessage
        case .offline: Self.offlineMessage
        case .signInRequired:
            link == .emailConfirmation ? Self.confirmedSignInMessage : Self.malformedMessage
        }
    }

    // MARK: - Classification

    /// Checks the redirect URL before anything is sent to Supabase. Returns `nil`
    /// when the URL carries a PKCE code and no error, i.e. it is worth exchanging.
    static func redirectFailure(link: AuthDeepLink, url: URL) -> AuthLinkFailure? {
        let params = redirectParameters(in: url)
        if params["error"] != nil || params["error_code"] != nil || params["error_description"] != nil {
            return reason(forErrorCode: params["error_code"])
        }
        if let code = params["code"], !code.isEmpty { return nil }
        if link == .emailConfirmation, params["access_token"] != nil { return .signInRequired }
        return .malformed
    }

    /// Classifies the error `session(from:)` threw for a URL that passed `redirectFailure`.
    static func exchangeFailure(from error: Error) -> AuthLinkFailure {
        if error is URLError { return .offline }
        guard let authError = error as? Auth.AuthError else { return .expired }

        if case let .api(_, errorCode, _, _) = authError {
            // A code was present (redirectFailure checked), so the empty value the
            // server rejected is the code verifier this device doesn't have.
            if errorCode == .validationFailed { return .differentDevice }
            return reason(forErrorCode: errorCode.rawValue)
        }
        if case let .pkceGrantCodeExchange(_, _, code) = authError {
            // The SDK's own redirect parsing ("No code detected." has no code).
            return code.map { reason(forErrorCode: $0) } ?? .malformed
        }
        return .expired
    }

    /// Server/redirect error codes shared by both paths; unknown codes fall back.
    private static func reason(forErrorCode code: String?) -> AuthLinkFailure {
        switch code {
        case ErrorCode.otpExpired.rawValue, ErrorCode.flowStateExpired.rawValue: .expired
        case ErrorCode.flowStateNotFound.rawValue: .alreadyUsed
        case ErrorCode.badCodeVerifier.rawValue: .olderRequest
        default: .expired
        }
    }

    /// Query and fragment parameters, percent-decoded. Query wins on a clash, as in the SDK.
    private static func redirectParameters(in url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        var result: [String: String] = [:]
        if let fragment = components.percentEncodedFragment, !fragment.isEmpty {
            // A parsed URL's fragment is validly percent-encoded with the same
            // character set a query allows, so it can be read as one.
            var fragmentComponents = URLComponents()
            fragmentComponents.percentEncodedQuery = fragment
            for item in fragmentComponents.queryItems ?? [] { result[item.name] = item.value ?? "" }
        }
        for item in components.queryItems ?? [] { result[item.name] = item.value ?? "" }
        return result
    }
}

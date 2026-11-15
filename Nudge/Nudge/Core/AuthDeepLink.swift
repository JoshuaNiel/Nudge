import Foundation

/// The auth email links the app understands.
///
/// Supabase emails a link to its own `/verify` endpoint, which then redirects to
/// one of these custom-scheme URLs with a PKCE `?code=` (or error params)
/// attached. This type only *classifies* an incoming URL; it never trusts its
/// contents. `supabase.auth.session(from:)` is what validates the code against
/// the verifier stored on this device.
///
/// The scheme must match `CFBundleURLTypes` in `Nudge/Info.plist`, and
/// `nudge://**` must be listed under Authentication → URL Configuration →
/// Redirect URLs in the Supabase dashboard.
enum AuthDeepLink: Equatable {
    /// `nudge://reset-password` — the user tapped a password-reset email.
    case passwordRecovery
    /// `nudge://auth-callback` — the user tapped a sign-up confirmation email.
    case emailConfirmation

    static let scheme = "nudge"

    private var host: String {
        switch self {
        case .passwordRecovery: "reset-password"
        case .emailConfirmation: "auth-callback"
        }
    }

    /// The `redirectTo` URL sent to Supabase when requesting the email.
    var redirectURL: URL {
        // Force-unwrap is safe: both strings are compile-time constants.
        URL(string: "\(Self.scheme)://\(host)")!
    }

    /// Classifies `url`, returning `nil` for anything that isn't one of our auth links.
    ///
    /// Scheme and host compare case-insensitively (RFC 3986 §3.1, §3.2.2). Query and
    /// fragment are ignored here. Any path other than empty or `/` is rejected so
    /// that future `nudge://` routes can't be mistaken for auth links.
    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme,
              let host = components.host?.lowercased(),
              components.path.isEmpty || components.path == "/" else {
            return nil
        }
        switch host {
        case Self.passwordRecovery.host: self = .passwordRecovery
        case Self.emailConfirmation.host: self = .emailConfirmation
        default: return nil
        }
    }
}

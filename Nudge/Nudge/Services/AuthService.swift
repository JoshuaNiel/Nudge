import Foundation
import Supabase
import AuthenticationServices

@MainActor
class AuthService {

    // MARK: - Email/Password

    func signUp(email: String, password: String) async throws {
        try await supabase.auth.signUp(email: email, password: password)
    }

    func signIn(email: String, password: String) async throws {
        try await supabase.auth.signIn(email: email, password: password)
    }

    func signOut() async throws {
        try await supabase.auth.signOut()
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
            .from("profiles")
            .update(["firstName": firstName, "lastName": lastName])
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

    var errorDescription: String? {
        switch self {
        case .missingAppleIdentityToken:
            return "Could not retrieve Apple identity token."
        case .notAuthenticated:
            return "No authenticated user found."
        }
    }
}

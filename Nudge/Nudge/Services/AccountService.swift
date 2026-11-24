import Foundation
import Supabase

// MARK: - Protocols

/// Server side of in-app account deletion (docs/specs/account-deletion.md, sections B + C).
protocol AccountServiceProtocol {
    /// Re-authenticates with `password`, then permanently deletes the signed-in user's account
    /// and all of their data on the server. Throws if either step fails; in that case nothing
    /// was deleted and the caller must leave local state untouched.
    func deleteAccount(password: String) async throws
}

/// Password re-authentication against Supabase Auth.
protocol PasswordReauthenticating {
    /// The email of the user in the current session, or nil if there is none.
    func currentUserEmail() -> String?
    /// Signs in with email + password, replacing the session with a fresh one. Returns the new
    /// session's access token. Throws the SDK's error unchanged.
    func signIn(email: String, password: String) async throws -> String
}

/// Calls the `delete-account` Edge Function.
protocol DeleteAccountFunctionInvoking {
    /// Throws the SDK's error unchanged (e.g. `FunctionsError.httpError` on a non-2xx).
    func invoke(accessToken: String) async throws
}

// MARK: - Service

/// Two layers guard deletion (spec section C): this service re-authenticates with the
/// password first (layer 1), and the function independently requires the token to record a
/// recent password sign-in (layer 2).
@MainActor
class AccountService: AccountServiceProtocol {

    private let auth: PasswordReauthenticating
    private let deleteFunction: DeleteAccountFunctionInvoking

    // Production init — real Supabase auth + functions clients.
    init() {
        self.auth = SupabasePasswordReauthenticator()
        self.deleteFunction = SupabaseDeleteAccountFunction()
    }

    // Test init — mocks.
    init(auth: PasswordReauthenticating, deleteFunction: DeleteAccountFunctionInvoking) {
        self.auth = auth
        self.deleteFunction = deleteFunction
    }

    func deleteAccount(password: String) async throws {
        // No current user / no email → nothing is sent anywhere.
        guard let email = auth.currentUserEmail(), !email.isEmpty else {
            throw AccountServiceError.notAuthenticated
        }

        // Layer 1. The password is passed exactly as typed (whitespace is valid in passwords).
        let accessToken: String
        do {
            accessToken = try await auth.signIn(email: email, password: password)
        } catch {
            throw AccountServiceError.mapSignInError(error)
        }

        // Only reached after a successful re-auth. Use the NEW token: it is the one whose
        // `amr` records a password sign-in just now, which layer 2 checks.
        do {
            try await deleteFunction.invoke(accessToken: accessToken)
        } catch {
            throw AccountServiceError.mapFunctionError(error)
        }
    }
}

// MARK: - Production adapters

@MainActor
struct SupabasePasswordReauthenticator: PasswordReauthenticating {
    func currentUserEmail() -> String? {
        supabase.auth.currentUser?.email
    }

    func signIn(email: String, password: String) async throws -> String {
        // On success the SDK stores the new session (and emits `.signedIn`); on failure the
        // existing session is left untouched.
        let session = try await supabase.auth.signIn(email: email, password: password)
        return session.accessToken
    }
}

@MainActor
struct SupabaseDeleteAccountFunction: DeleteAccountFunctionInvoking {
    func invoke(accessToken: String) async throws {
        // The token is set explicitly rather than relying on the functions client's implicit
        // header (which falls back to the anon key if no session was propagated yet). No body:
        // the function deletes only the user identified by this token.
        try await supabase.functions.invoke(
            "delete-account",
            options: FunctionInvokeOptions(
                method: .post,
                headers: ["Authorization": "Bearer \(accessToken)"]
            )
        )
    }
}

// MARK: - Errors

enum AccountServiceError: LocalizedError, Equatable {
    case notAuthenticated
    /// Re-auth rejected the password (`invalid_credentials`).
    case incorrectPassword
    /// Supabase Auth rate limit (HTTP 429 / `over_request_rate_limit`).
    case rateLimited
    /// The function answered 403 `{"error":"reauth_required"}`: the token's password sign-in
    /// was missing or too old.
    case reauthRequired
    /// The function answered with any other non-2xx status.
    case serverRejected(status: Int)

    /// Developer-facing only (logs); the ViewModel picks the user-facing copy.
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You're not signed in."
        case .incorrectPassword:
            return "Re-authentication failed: invalid credentials."
        case .rateLimited:
            return "Re-authentication was rate limited."
        case .reauthRequired:
            return "The server requires a recent password sign-in."
        case .serverRejected(let status):
            return "The server couldn't delete the account (status \(status))."
        }
    }

    /// Maps a password sign-in failure. Anything unrecognized (network, cancellation, other
    /// Auth API errors) passes through unchanged.
    static func mapSignInError(_ error: Error) -> Error {
        // `Auth.` qualifies past the app's own `AuthError` enum (AuthService.swift).
        guard let authError = error as? Auth.AuthError else { return error }
        if authError.errorCode == .invalidCredentials {
            return AccountServiceError.incorrectPassword
        }
        if authError.errorCode == .overRequestRateLimit {
            return AccountServiceError.rateLimited
        }
        if case .api(_, _, _, let response) = authError, response.statusCode == 429 {
            return AccountServiceError.rateLimited
        }
        return error
    }

    /// Maps a non-2xx Edge Function response; any other error (network, cancellation) passes
    /// through unchanged.
    static func mapFunctionError(_ error: Error) -> Error {
        guard case FunctionsError.httpError(let code, let data) = error else { return error }
        if code == 403, FunctionErrorBody.decode(data)?.error == "reauth_required" {
            return AccountServiceError.reauthRequired
        }
        return AccountServiceError.serverRejected(status: code)
    }
}

/// The function's JSON error body: `{ "error": "<message>" }`.
private struct FunctionErrorBody: Decodable {
    let error: String

    static func decode(_ data: Data) -> FunctionErrorBody? {
        try? JSONDecoder().decode(FunctionErrorBody.self, from: data)
    }
}

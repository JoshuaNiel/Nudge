import Foundation
import Supabase

// MARK: - Protocol

/// Server side of in-app account deletion (docs/specs/account-deletion.md).
protocol AccountServiceProtocol {
    /// Permanently deletes the signed-in user's account and all of their data on the server.
    /// Throws if the server did not confirm the deletion; in that case nothing was deleted
    /// locally and the caller must leave local state untouched.
    func deleteAccount() async throws
}

// MARK: - Service

@MainActor
class AccountService: AccountServiceProtocol {

    func deleteAccount() async throws {
        // `session` refreshes an expired access token, so the function always receives a
        // current user JWT — never the anon key the functions client falls back to when it
        // has not been handed a session yet.
        guard let session = try? await supabase.auth.session else {
            throw AccountServiceError.notAuthenticated
        }

        do {
            // No body: the function deletes only the user identified by this token.
            try await supabase.functions.invoke(
                "delete-account",
                options: FunctionInvokeOptions(
                    method: .post,
                    headers: ["Authorization": "Bearer \(session.accessToken)"]
                )
            )
        } catch {
            throw AccountServiceError.map(error)
        }
    }
}

// MARK: - Errors

enum AccountServiceError: LocalizedError, Equatable {
    case notAuthenticated
    /// The function answered with a non-2xx status.
    case serverRejected(status: Int)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You're not signed in."
        case .serverRejected(let status):
            return "The server couldn't delete the account (status \(status))."
        }
    }

    /// Maps a non-2xx Edge Function response to `.serverRejected`; any other error
    /// (network, cancellation) passes through unchanged.
    static func map(_ error: Error) -> Error {
        if case FunctionsError.httpError(let code, _) = error {
            return AccountServiceError.serverRejected(status: code)
        }
        return error
    }
}

import Foundation
import Combine

/// Drives the "Forgot password?" sheet.
///
/// Security: the UI must never reveal whether an account exists for an email.
/// Every server response — success or failure — shows the same neutral message.
/// The only exceptions are a rate limit (which Supabase returns regardless of
/// whether the account exists) and a transport failure (the request never
/// reached the server, so it carries no information about the account).
@MainActor
final class ForgotPasswordViewModel: ObservableObject {

    enum Status: Equatable {
        case idle
        case sending
        case sent
        case rateLimited
        case offline
    }

    static let instructionsMessage = "Enter the email you use for Nudge and we'll send you a link to choose a new password. Open the link on this device."
    static let neutralMessage = "If an account exists for that email, we've sent a reset link."
    static let offlineMessage = "Couldn't reach Nudge. Check your connection and try again."
    static let invalidEmailMessage = "Please enter a valid email address."

    @Published var email: String
    @Published private(set) var status: Status = .idle
    @Published private(set) var validationError: String? = nil

    private let service: AuthRecoveryServiceProtocol

    // Production init — uses the real service
    init(email: String) {
        self.email = email
        self.service = AuthService()
    }

    // Test init — accepts a mock
    init(email: String, service: AuthRecoveryServiceProtocol) {
        self.email = email
        self.service = service
    }

    // MARK: - Computed

    var isSending: Bool { status == .sending }

    var canSubmit: Bool {
        !isSending && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var statusMessage: String? {
        switch status {
        case .idle, .sending: nil
        case .sent: Self.neutralMessage
        case .rateLimited: AuthErrorMapping.busyMessage
        case .offline: Self.offlineMessage
        }
    }

    // MARK: - Actions

    func submit() async {
        validationError = nil
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isValidEmail else {
            validationError = Self.invalidEmailMessage
            return
        }

        status = .sending
        do {
            try await service.sendPasswordReset(email: trimmed)
            status = .sent
        } catch {
            status = Self.status(for: error)
        }
    }

    /// Maps a failed reset request to what the user sees. Anything that isn't a
    /// rate limit or a transport failure is deliberately reported as `.sent`.
    private static func status(for error: Error) -> Status {
        if AuthErrorMapping.isRateLimited(error) { return .rateLimited }
        if error is URLError { return .offline }
        return .sent
    }
}

import Foundation
import Combine
import os

enum AccountDeletionState: Equatable {
    case idle
    case confirming
    case deleting
    case done
    case failed(String)
}

/// State machine for Settings → Delete Account (docs/specs/account-deletion.md, B–D):
/// `idle → confirming → deleting → done | failed(message)`.
///
/// `confirming`, `deleting` and `failed` are all shown in the password sheet; a failure
/// keeps the sheet open with the message inline and the password cleared, so the user can
/// retry (`failed → deleting`) or cancel (`→ idle`).
///
/// Local cleanup runs only after the server confirms the deletion. On failure nothing local
/// changes, so the user is still signed in and can retry.
@MainActor
class AccountDeletionViewModel: ObservableObject {

    static let confirmationMessage =
        "Your account, friends, goals, and history will be permanently removed, and your "
        + "friends will receive no further texts from Nudge. This cannot be undone."

    static let incorrectPasswordMessage = "Incorrect password."
    static let rateLimitedMessage = "Too many attempts. Try again in a few minutes."
    static let reauthRequiredMessage = "Please enter your password again."
    /// Generic on purpose: transport/server details never reach the UI.
    static let failureMessage = "Couldn't delete your account. Check your connection and try again."

    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "AccountDeletion")

    @Published private(set) var state: AccountDeletionState = .idle
    /// Bound to the sheet's `SecureField`. Cleared after every attempt and on cancel.
    @Published var password = ""

    /// The in-flight deletion, exposed so tests can await completion.
    private(set) var deletionTask: Task<Void, Never>?

    private let accountService: AccountServiceProtocol
    private let cleanup: AccountCleanupProtocol

    // Production init — uses real services
    init() {
        self.accountService = AccountService()
        self.cleanup = AccountCleanupService()
    }

    // Test init — accepts mocks
    init(accountService: AccountServiceProtocol, cleanup: AccountCleanupProtocol) {
        self.accountService = accountService
        self.cleanup = cleanup
    }

    // MARK: - Computed

    var isConfirming: Bool { state == .confirming }
    var isDeleting: Bool { state == .deleting }

    /// Whether the password sheet is up.
    var isSheetPresented: Bool {
        switch state {
        case .confirming, .deleting, .failed: return true
        case .idle, .done: return false
        }
    }

    /// The destructive button is enabled only with a non-empty password (not trimmed —
    /// whitespace is valid in passwords) and when no request is in flight.
    var canSubmit: Bool {
        guard !password.isEmpty else { return false }
        switch state {
        case .confirming, .failed: return true
        case .idle, .deleting, .done: return false
        }
    }

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    // MARK: - Actions

    /// Settings "Delete Account" tapped → open the password sheet.
    func requestDeletion() {
        guard state == .idle else { return }
        password = ""
        state = .confirming
    }

    /// Sheet "Cancel" (or swipe-dismiss, which is disabled while deleting).
    func cancelDeletion() {
        switch state {
        case .confirming, .failed:
            password = ""
            state = .idle
        case .idle, .deleting, .done:
            break
        }
    }

    /// Sheet "Delete Account". Enters `.deleting` synchronously so the button is disabled
    /// before the next tap can land; any further tap is ignored until the request settles.
    ///
    /// `presenter` is told once the server confirms (never on failure), so the
    /// "Account Deleted" page replaces the app (spec D).
    func confirmDeletion(notifying presenter: AccountDeletedPresenting) {
        guard canSubmit else { return }
        let password = self.password
        state = .deleting
        deletionTask = Task { await performDeletion(password: password, presenter: presenter) }
    }

    // MARK: - Private

    private func performDeletion(password: String, presenter: AccountDeletedPresenting) async {
        do {
            try await accountService.deleteAccount(password: password)
        } catch {
            Self.logger.error("account deletion failed: \(error.localizedDescription, privacy: .public)")
            self.password = ""
            state = .failed(Self.message(for: error))
            return
        }
        self.password = ""
        // Server confirmed. Show the Account Deleted page *before* cleanup: its last step ends
        // the session (`.signedOut`), and RootView must already be on the page by then or it
        // would flash the onboarding tour.
        presenter.presentAccountDeleted()
        // The account no longer exists, so local state must go too.
        await cleanup.performPostDeletionCleanup()
        state = .done
    }

    /// User-facing copy for each row of the spec's error table.
    static func message(for error: Error) -> String {
        switch error as? AccountServiceError {
        case .incorrectPassword: return incorrectPasswordMessage
        case .rateLimited: return rateLimitedMessage
        case .reauthRequired: return reauthRequiredMessage
        case .notAuthenticated, .serverRejected, nil: return failureMessage
        }
    }
}

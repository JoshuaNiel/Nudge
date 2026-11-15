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

/// State machine for Settings → Delete Account:
/// `idle → confirming → deleting → done | failed(message)`.
///
/// Local cleanup runs only after the server confirms the deletion. On failure nothing local
/// changes, so the user is still signed in and can retry.
@MainActor
class AccountDeletionViewModel: ObservableObject {

    static let confirmationMessage =
        "Your account, friends, goals, and history will be permanently removed, and your "
        + "friends will receive no further texts from Nudge. This cannot be undone."

    /// Generic on purpose: transport/server details never reach the UI.
    static let failureMessage =
        "We couldn't delete your account. Nothing was changed. Check your connection and try again."

    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "AccountDeletion")

    @Published private(set) var state: AccountDeletionState = .idle

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

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    // MARK: - Actions

    /// "Delete Account" tapped → show the confirmation alert.
    func requestDeletion() {
        switch state {
        case .idle, .failed:
            state = .confirming
        case .confirming, .deleting, .done:
            break
        }
    }

    /// Alert "Cancel".
    func cancelDeletion() {
        guard state == .confirming else { return }
        state = .idle
    }

    /// Alert "Delete". Enters `.deleting` synchronously so the button is disabled before the
    /// alert finishes dismissing; any further tap is ignored until the request settles.
    func confirmDeletion() {
        guard state == .confirming else { return }
        state = .deleting
        deletionTask = Task { await performDeletion() }
    }

    /// Error alert "OK".
    func dismissError() {
        guard case .failed = state else { return }
        state = .idle
    }

    // MARK: - Private

    private func performDeletion() async {
        do {
            try await accountService.deleteAccount()
        } catch {
            Self.logger.error("account deletion failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(Self.failureMessage)
            return
        }
        // Server confirmed — the account no longer exists, so local state must go too.
        await cleanup.performPostDeletionCleanup()
        state = .done
    }
}

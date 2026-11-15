import Foundation
import Combine
import os

/// Owns the auth sheets that must outlive `RootView`'s branch switches.
///
/// Handling an auth link establishes a session, which flips `AppState` and makes
/// `RootView` swap between onboarding and the main app. A sheet presented from
/// inside either branch would be torn down by that swap, so both auth sheets are
/// presented from `NudgeApp`, above `RootView`, and driven from here.
///
/// A single `activeSheet` (rather than one Bool per sheet) lets SwiftUI swap the
/// forgot-password sheet for the set-new-password sheet in one step when the
/// reset link arrives while the first is still open.
@MainActor
final class AuthRecoveryCoordinator: ObservableObject {

    enum Sheet: Identifiable, Equatable {
        case forgotPassword(prefillEmail: String)
        case setNewPassword

        var id: String {
            switch self {
            case .forgotPassword: "forgotPassword"
            case .setNewPassword: "setNewPassword"
            }
        }
    }

    static let expiredLinkMessage = "This link has expired. Request a new one."

    @Published var activeSheet: Sheet? = nil
    @Published var isShowingExpiredLinkAlert = false

    /// Set when the expired-link alert has to wait for a sheet to finish dismissing
    /// (SwiftUI can't present an alert from a view that is presenting a sheet).
    private var alertPendingDismiss = false

    private let service: AuthRecoveryServiceProtocol
    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "AuthRecovery")

    // Production init — uses the real service
    init() {
        self.service = AuthService()
    }

    // Test init — accepts a mock
    init(service: AuthRecoveryServiceProtocol) {
        self.service = service
    }

    // MARK: - Sheet control

    func presentForgotPassword(prefillEmail: String) {
        activeSheet = .forgotPassword(prefillEmail: prefillEmail)
    }

    func dismissSheet() {
        activeSheet = nil
    }

    /// Wire to the sheet's `onDismiss`. Raises any alert that was waiting on it.
    func sheetDidDismiss() {
        guard alertPendingDismiss else { return }
        alertPendingDismiss = false
        isShowingExpiredLinkAlert = true
    }

    // MARK: - Deep links

    /// Entry point for `.onOpenURL`. Ignores URLs that aren't auth links.
    func handleOpenURL(_ url: URL) async {
        guard let link = AuthDeepLink(url: url) else { return }

        do {
            try await service.establishSession(from: url)
        } catch {
            // The URL carries a one-time code; never log it.
            Self.logger.error("auth link rejected (\(String(describing: link), privacy: .public)): \(error.localizedDescription, privacy: .public)")
            showExpiredLinkAlert()
            return
        }

        switch link {
        case .passwordRecovery:
            activeSheet = .setNewPassword
        case .emailConfirmation:
            // Signed in now; AppState + RootView take it from here.
            if case .forgotPassword = activeSheet { activeSheet = nil }
        }
    }

    private func showExpiredLinkAlert() {
        switch activeSheet {
        case .none:
            isShowingExpiredLinkAlert = true
        case .forgotPassword:
            // Close the sheet, then alert once it is gone (see sheetDidDismiss).
            alertPendingDismiss = true
            activeSheet = nil
        case .setNewPassword:
            // A valid recovery session is already in progress; a stale second
            // link shouldn't interrupt it.
            break
        }
    }
}

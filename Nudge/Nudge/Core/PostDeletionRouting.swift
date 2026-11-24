import Foundation

/// Receives "the server confirmed the account is deleted" from the deletion flow, so the
/// "Account Deleted" page can be shown (docs/specs/account-deletion.md, section D).
/// `AppState` conforms in production; tests inject a mock.
protocol AccountDeletedPresenting: AnyObject {
    func presentAccountDeleted()
}

/// What RootView shows around an in-app account deletion (spec D).
///
/// In memory only, by design: nothing about the deleted account is stored on the device, and
/// if the app is killed on the page the next launch shows the normal start (the tour).
struct PostDeletionRouting: Equatable {
    /// True from the moment the server confirms the deletion until "Back to Sign In".
    private(set) var isShowingAccountDeleted = false

    /// Where the next `OnboardingCoordinator` starts. `.auth` only for the sign-in that
    /// follows a deletion (the user has already seen the tour).
    private(set) var onboardingStart: OnboardingCoordinator.Step = .tour

    /// Server confirmed the deletion.
    mutating func accountDeleted() {
        isShowingAccountDeleted = true
    }

    /// "Back to Sign In" on the Account Deleted page.
    mutating func backToSignIn() {
        isShowingAccountDeleted = false
        onboardingStart = .auth
    }

    /// A user signed in. The coordinator already on screen keeps its current step (`@State`
    /// reads its initial value only once); any later sign-out starts at the tour again.
    mutating func signedIn() {
        onboardingStart = .tour
    }
}

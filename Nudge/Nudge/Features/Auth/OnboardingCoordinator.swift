import SwiftUI

/// Drives the signed-out part of onboarding: feature tour → auth (→ confirm email).
///
/// Once a session exists (from AuthView's own submit or from an email link), `RootView`
/// replaces this view with the signed-in destination decided by `OnboardingRouting`
/// (profile setup → permissions → app; docs/specs/onboarding-progress.md §4).
///
/// Starts at the tour by default. After an in-app account deletion ("Back to Sign In",
/// account-deletion spec D) it starts at `.auth`, skipping the tour.
struct OnboardingCoordinator: View {
    @EnvironmentObject private var authRecovery: AuthRecoveryCoordinator

    /// The step this coordinator was created at. Read once: later changes are ignored.
    let initialStep: Step
    @State private var step: Step
    /// Email to prefill when returning to the sign-in form from the confirm-email screen.
    @State private var authPrefillEmail = ""

    enum Step: Equatable {
        case tour
        case auth
        /// Waiting for the emailed confirmation link (auth-recovery spec C5). Carries the
        /// Resend credentials, which are dropped when the step changes.
        case confirmEmail(PendingEmailConfirmation)
    }

    init(startingAt initialStep: Step = .tour) {
        self.initialStep = initialStep
        self._step = State(initialValue: initialStep)
    }

    var body: some View {
        switch step {
        case .tour:
            OnboardingTourView(onFinished: { step = .auth })
        case .auth:
            AuthView(
                prefillEmail: authPrefillEmail,
                // RootView moves on when the session is published.
                onAuthenticated: {},
                onConfirmationRequired: { pending in step = .confirmEmail(pending) },
                onForgotPassword: { email in authRecovery.presentForgotPassword(prefillEmail: email) }
            )
        case .confirmEmail(let pending):
            ConfirmEmailView(
                pending: pending,
                onAuthenticated: {},
                onBackToSignIn: { email in
                    authPrefillEmail = email
                    step = .auth
                }
            )
        }
    }
}

#Preview {
    OnboardingCoordinator()
        .environmentObject(AppState())
        .environmentObject(AuthRecoveryCoordinator())
}

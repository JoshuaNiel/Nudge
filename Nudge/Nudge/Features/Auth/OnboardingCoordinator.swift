import SwiftUI

/// Drives the full onboarding sequence:
/// feature tour → auth (→ confirm email) → profile setup → permissions → done
///
/// Starts at the tour by default. After an in-app account deletion ("Back to Sign In",
/// account-deletion spec D) it starts at `.auth`, skipping the tour.
struct OnboardingCoordinator: View {
    @Binding var onboardingComplete: Bool
    @EnvironmentObject private var appState: AppState
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
        case profileSetup
        case permissions

        /// Signed-out steps: a session arriving from an email link moves past them.
        var advancesOnSignIn: Bool {
            switch self {
            case .tour, .auth, .confirmEmail: true
            case .profileSetup, .permissions: false
            }
        }
    }

    init(onboardingComplete: Binding<Bool>, startingAt initialStep: Step = .tour) {
        self._onboardingComplete = onboardingComplete
        self.initialStep = initialStep
        self._step = State(initialValue: initialStep)
    }

    var body: some View {
        content
            // A session can also arrive from an email link (sign-up confirmation or
            // password reset) rather than from AuthView's own submit. Advance past
            // the pre-auth steps so the user isn't left on a sign-in form while
            // already signed in.
            .onChange(of: appState.isAuthenticated) { _, isAuthenticated in
                if isAuthenticated && step.advancesOnSignIn {
                    step = .profileSetup
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .tour:
            OnboardingTourView(onFinished: { step = .auth })
        case .auth:
            AuthView(
                prefillEmail: authPrefillEmail,
                onAuthenticated: { step = .profileSetup },
                onConfirmationRequired: { pending in step = .confirmEmail(pending) },
                onForgotPassword: { email in authRecovery.presentForgotPassword(prefillEmail: email) }
            )
        case .confirmEmail(let pending):
            ConfirmEmailView(
                pending: pending,
                onAuthenticated: { step = .profileSetup },
                onBackToSignIn: { email in
                    authPrefillEmail = email
                    step = .auth
                }
            )
        case .profileSetup:
            ProfileSetupView(onCompleted: { step = .permissions })
        case .permissions:
            PermissionsView(onCompleted: { onboardingComplete = true })
        }
    }
}

#Preview {
    OnboardingCoordinator(onboardingComplete: .constant(false))
        .environmentObject(AppState())
        .environmentObject(AuthRecoveryCoordinator())
}

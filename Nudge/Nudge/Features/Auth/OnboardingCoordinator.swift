import SwiftUI

/// Drives the full onboarding sequence:
/// feature tour → auth → profile setup → permissions → done
struct OnboardingCoordinator: View {
    @Binding var onboardingComplete: Bool
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authRecovery: AuthRecoveryCoordinator

    @State private var step: Step = .tour

    private enum Step {
        case tour
        case auth
        case profileSetup
        case permissions
    }

    var body: some View {
        content
            // A session can also arrive from an email link (sign-up confirmation or
            // password reset) rather than from AuthView's own submit. Advance past
            // the pre-auth steps so the user isn't left on a sign-in form while
            // already signed in.
            .onChange(of: appState.isAuthenticated) { _, isAuthenticated in
                if isAuthenticated && (step == .tour || step == .auth) {
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
                onAuthenticated: { step = .profileSetup },
                onForgotPassword: { email in authRecovery.presentForgotPassword(prefillEmail: email) }
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

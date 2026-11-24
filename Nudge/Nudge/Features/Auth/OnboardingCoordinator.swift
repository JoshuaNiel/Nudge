import SwiftUI

/// Drives the full onboarding sequence:
/// feature tour → auth → profile setup → permissions → done
///
/// Starts at the tour by default. After an in-app account deletion ("Back to Sign In",
/// account-deletion spec D) it starts at `.auth`, skipping the tour.
struct OnboardingCoordinator: View {
    @Binding var onboardingComplete: Bool
    @EnvironmentObject private var appState: AppState

    /// The step this coordinator was created at. Read once: later changes are ignored.
    let initialStep: Step
    @State private var step: Step

    enum Step {
        case tour
        case auth
        case profileSetup
        case permissions
    }

    init(onboardingComplete: Binding<Bool>, startingAt initialStep: Step = .tour) {
        self._onboardingComplete = onboardingComplete
        self.initialStep = initialStep
        self._step = State(initialValue: initialStep)
    }

    var body: some View {
        switch step {
        case .tour:
            OnboardingTourView(onFinished: { step = .auth })
        case .auth:
            AuthView(onAuthenticated: { step = .profileSetup })
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
}

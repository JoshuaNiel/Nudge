import SwiftUI

/// Drives the full onboarding sequence:
/// feature tour → auth → profile setup → permissions → done
struct OnboardingCoordinator: View {
    @Binding var onboardingComplete: Bool
    @EnvironmentObject private var appState: AppState

    @State private var step: Step = .tour

    private enum Step {
        case tour
        case auth
        case profileSetup
        case permissions
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

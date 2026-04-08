import SwiftUI

/// Root view that gates the app based on auth state and onboarding completion.
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some View {
        if appState.isLoading {
            // Briefly shown while the Supabase session check completes
            ProgressView()
        } else if !appState.isAuthenticated || !onboardingComplete {
            OnboardingCoordinator(onboardingComplete: $onboardingComplete)
        } else {
            ContentView()
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppState())
}

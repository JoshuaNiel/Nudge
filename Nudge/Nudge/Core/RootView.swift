import SwiftUI

/// Root view that gates the app based on auth state and onboarding completion.
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage(AppStorageKeys.onboardingComplete) private var onboardingComplete = false

    enum Screen: Equatable {
        case loading
        case accountDeleted
        case onboarding
        case main
    }

    /// The Account Deleted page is checked before auth/onboarding state: it is set before the
    /// post-deletion cleanup resets `onboardingComplete` and ends the session, so it stays on
    /// screen through that whole transition and the tour never flashes (account-deletion spec D).
    static func screen(
        isLoading: Bool,
        isShowingAccountDeleted: Bool,
        isAuthenticated: Bool,
        onboardingComplete: Bool
    ) -> Screen {
        if isLoading { return .loading }
        if isShowingAccountDeleted { return .accountDeleted }
        if !isAuthenticated || !onboardingComplete { return .onboarding }
        return .main
    }

    var body: some View {
        switch currentScreen {
        case .loading:
            // Briefly shown while the Supabase session check completes
            ProgressView()
        case .accountDeleted:
            AccountDeletedView(onBackToSignIn: appState.backToSignInAfterDeletion)
        case .onboarding:
            OnboardingCoordinator(
                onboardingComplete: $onboardingComplete,
                startingAt: appState.postDeletion.onboardingStart
            )
        case .main:
            ContentView()
        }
    }

    private var currentScreen: Screen {
        Self.screen(
            isLoading: appState.isLoading,
            isShowingAccountDeleted: appState.postDeletion.isShowingAccountDeleted,
            isAuthenticated: appState.isAuthenticated,
            onboardingComplete: onboardingComplete
        )
    }
}

#Preview {
    RootView()
        .environmentObject(AppState())
        .environmentObject(PushRouter())
}

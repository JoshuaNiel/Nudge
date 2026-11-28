import SwiftUI
internal import Auth  // `User.id` on `appState.currentUser`

/// Root view: gates the app on auth state and the signed-in user's onboarding progress
/// (docs/specs/onboarding-progress.md §4).
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var onboarding: OnboardingProgressController
    @EnvironmentObject private var permissions: PermissionStatusStore
    @EnvironmentObject private var permissionsPage: PermissionsPageTracker

    enum Screen: Equatable {
        case loading
        case accountDeleted
        /// Signed out: tour → auth (→ confirm email).
        case onboarding
        case profileSetup
        case permissions(pending: [DevicePermission])
        case main
    }

    /// The Account Deleted page is checked before auth/onboarding state: it is set before the
    /// post-deletion cleanup clears the onboarding copy and ends the session, so it stays on
    /// screen through that whole transition and the tour never flashes (account-deletion spec D).
    ///
    /// `destination` is `nil` while the signed-in user's progress or the permission statuses
    /// are still loading.
    static func screen(
        isLoading: Bool,
        isShowingAccountDeleted: Bool,
        isAuthenticated: Bool,
        destination: OnboardingDestination?
    ) -> Screen {
        if isLoading { return .loading }
        if isShowingAccountDeleted { return .accountDeleted }
        guard isAuthenticated else { return .onboarding }
        switch destination {
        case nil: return .loading
        case .profileSetup: return .profileSetup
        case .permissions(let pending): return .permissions(pending: pending)
        case .app: return .main
        }
    }

    var body: some View {
        content
            // Load (or seed) the signed-in user's device copy; clear it from memory on sign-out.
            .task(id: appState.currentUser?.id) {
                await onboarding.prepare(userId: appState.currentUser?.id)
            }
            .task {
                if !permissions.isLoaded { await permissions.refresh() }
            }
            // The name saved in profile setup shows at once, offline too (device finding D);
            // the server profile replaces it once it has one.
            .onChange(of: deviceFirstName, initial: true) { _, name in
                appState.setDeviceFirstName(name)
            }
    }

    /// The signed-in user's first name from their onboarding device copy.
    private var deviceFirstName: String? {
        guard onboarding.userId == appState.currentUser?.id else { return nil }
        return onboarding.progress?.firstName
    }

    @ViewBuilder
    private var content: some View {
        switch currentScreen {
        case .loading:
            // Briefly shown while the Supabase session check (or a first-launch seed) completes
            NudgeLoadingIndicator()
        case .accountDeleted:
            AccountDeletedView(onBackToSignIn: appState.backToSignInAfterDeletion)
        case .onboarding:
            OnboardingCoordinator(startingAt: appState.postDeletion.onboardingStart)
        case .profileSetup:
            ProfileSetupView(
                initialFirstName: onboarding.progress?.firstName,
                initialLastName: onboarding.progress?.lastName,
                onSave: onboarding.saveProfileName
            )
        case .permissions(let pending):
            PermissionsView(
                pending: pending,
                onRequest: permissions.request,
                onFinished: finishPermissionsPage
            )
            // Reaching the page is what counts: it is never shown again on this device (§5b).
            .onAppear(perform: permissionsPage.markReached)
        case .main:
            ContentView()
        }
    }

    private var currentScreen: Screen {
        Self.screen(
            isLoading: appState.isLoading,
            isShowingAccountDeleted: appState.postDeletion.isShowingAccountDeleted,
            isAuthenticated: appState.isAuthenticated,
            destination: destination
        )
    }

    private var destination: OnboardingDestination? {
        guard let progress = onboarding.progress,
              onboarding.userId == appState.currentUser?.id,
              permissions.isLoaded else { return nil }
        return OnboardingRouting.destination(
            progress: progress,
            screenTime: permissions.screenTime,
            notifications: permissions.notifications,
            permissionsPageDone: permissionsPage.isFinished
        )
    }
}

extension RootView {
    // MARK: - Permissions

    /// Everything on the page was answered or skipped: the page is over on this device, and
    /// the account is completed (with every account step satisfied).
    private func finishPermissionsPage() {
        permissionsPage.finish()
        onboarding.markCompleted()
    }
}

#Preview {
    RootView()
        .environmentObject(AppState())
        .environmentObject(PushRouter())
        .environmentObject(OnboardingProgressController())
        .environmentObject(PermissionStatusStore())
        .environmentObject(PermissionsPageTracker())
}

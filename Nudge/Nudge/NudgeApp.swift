import SwiftUI
import BackgroundTasks
import os
import Supabase
internal import Auth

@main
struct NudgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    /// App-level so its sheets sit above RootView and survive its auth-driven branch switches.
    @StateObject private var authRecovery = AuthRecoveryCoordinator()
    /// The full-screen permissions page appears at most once per device (spec §5b). Declared
    /// before `onboarding`: its first-launch inference reads the legacy flag that
    /// `onboarding.prepare` deletes.
    @StateObject private var permissionsPage = PermissionsPageTracker()
    /// The signed-in user's onboarding progress (device copy + outbox; onboarding-progress spec).
    @StateObject private var onboarding = OnboardingProgressController()
    /// Screen Time + notification statuses for onboarding routing and the permission banners.
    @StateObject private var permissions = PermissionStatusStore()
    @Environment(\.scenePhase) private var scenePhase

    /// Runs `onForeground` once per trip to the foreground, never twice at once, and
    /// defers it until the user is known on a cold start (auth race).
    @State private var foregroundSync = ForegroundSync()
    /// Single-flight gate for the monitoring refresh, shared by the foreground sync and an
    /// in-app Screen Time approval (device finding C).
    @State private var monitoringRefresh = MonitoringRefreshCoordinator()

    private let monitoringService = MonitoringRegistrationService()
    private let goalService = GoalService()

    init() {
        registerBackgroundTasks()
        // Before any navigation bar exists: the main tabs' ~28pt large title (onboarding-progress §5d).
        MainTabHeaderAppearance.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(appDelegate.pushRouter)
                .environmentObject(onboarding)
                .environmentObject(permissions)
                .environmentObject(permissionsPage)
                .task {
                    // Route APNs tokens from the UIKit delegate to the session-aware manager.
                    // The delegate buffers a token that arrives before this runs.
                    appDelegate.setDeviceTokenHandler { [appState] token in
                        Task { await appState.pushTokens.didReceiveDeviceToken(token) }
                    }
                }
                .environmentObject(authRecovery)
                .sheet(item: $authRecovery.activeSheet, onDismiss: authRecovery.sheetDidDismiss) { sheet in
                    switch sheet {
                    case .forgotPassword(let prefillEmail):
                        ForgotPasswordView(prefillEmail: prefillEmail, onClose: authRecovery.dismissSheet)
                    case .setNewPassword:
                        SetNewPasswordView(onFinished: authRecovery.dismissSheet)
                    }
                }
                .alert(AuthLinkFailure.alertTitle, isPresented: $authRecovery.isShowingLinkAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(authRecovery.linkAlertMessage)
                }
                // Password-reset and email-confirmation links (nudge://…).
                .onOpenURL { url in
                    Task { await authRecovery.handleOpenURL(url) }
                }
                // An in-app Screen Time approval (banner, add-goal ask, permissions page)
                // re-registers monitoring now rather than on the next foreground.
                .onReceive(permissions.screenTimeApprovals) {
                    guard let userId = appState.currentUser?.id else { return }
                    monitoringRefresh.request(userId: userId, force: true, perform: refreshMonitoring)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            foregroundSync.scenePhaseChanged(
                to: newPhase,
                userId: appState.currentUser?.id,
                perform: onForeground
            )
            if newPhase == .active {
                // Cheap local reads, so on every activation: a return from Settings and an
                // answered system prompt both land here.
                Task { await permissions.refresh() }
            }
            if newPhase == .background {
                // Ask the OS to wake us later to drain any queued nudge triggers.
                scheduleNudgeTriggerProcessing()
            }
        }
        // Auth race recovery: a foreground that arrived before the session check
        // finished runs as soon as the user is known. Keyed on the id, not the whole
        // `User`, so token refreshes (which republish `currentUser`) don't fire it.
        .onChange(of: appState.currentUser?.id) { _, newUserId in
            foregroundSync.userChanged(to: newUserId, perform: onForeground)
        }
    }

    // MARK: - Foreground handler

    /// Called through `foregroundSync` only: once per foreground, one at a time.
    private func onForeground(userId: UUID) async {
        // Never prompts — onboarding's PermissionsView owns the permission request. Re-registering
        // each foreground keeps the stored token fresh (APNs may rotate it).
        await PushRegistration.registerIfAuthorized()

        await monitoringRefresh.request(userId: userId, force: false, perform: refreshMonitoring).value

        // Strategy 2: flush any queued nudge triggers now that we're in a reliable
        // (foregrounded) network context. Runs regardless of the outcome above —
        // triggers already on the queue are still worth sending.
        await NudgeTriggerService().drainPendingTriggers(userId: userId)

        // Last, so it never delays monitoring: queued offline writes (outbox), then the
        // onboarding device copy (its refresh joins this flush). Neither blocks the UI.
        await Outbox.shared.flush()?.value
        await onboarding.refresh()
    }

    /// Re-registers monitoring from freshly fetched goals. Called through
    /// `monitoringRefresh` only. `force` (an in-app Screen Time approval) registers even when
    /// the stored registration looks fresh.
    ///
    /// Both fetches must succeed before touching `DeviceActivityCenter`. A failed
    /// request used to arrive here as an empty goal list, indistinguishable from
    /// "this user has no goals" — which re-registered with zero events and silently
    /// disarmed every trigger until the next successful foreground (ADR-054).
    /// Leaving yesterday's registration in place is strictly safer than replacing it
    /// with one built from data we do not have.
    private func refreshMonitoring(userId: UUID, force: Bool) async {
        // Checked first (local reads, before the fetches), so an offline foreground still
        // notices. Not on a forced run: that follows an approval, and the activities are
        // expected to be gone until it re-registers.
        let lapsed = !force && monitoringService.activitiesLapsedSinceRegisteringToday()
        if lapsed {
            // FamilyControls keeps the launch-time status in-process and, on device, a revoke
            // throws nothing; monitoring registered earlier today vanishing is the signal.
            permissions.recordMonitoringOutcome(.notNeeded, activitiesLapsedToday: true)
        }
        guard await appState.fetchAndCacheProfile(userId: userId) else {
            NudgeApp.logger.error("profile fetch failed — leaving existing monitoring registration untouched")
            return
        }
        guard let goals = try? await goalService.fetchGoalSummaries(userId: userId) else {
            NudgeApp.logger.error("goal fetch failed — leaving existing monitoring registration untouched")
            return
        }
        let outcome = monitoringService.refreshMonitoring(
            goals: goals,
            sessionTimeoutMinutes: appState.sessionTimeoutMinutes,
            force: force
        )
        // `startMonitoring` throwing `.unauthorized` is the other (documented) revoke signal.
        permissions.recordMonitoringOutcome(outcome, activitiesLapsedToday: lapsed)
    }

    // MARK: - Background Tasks

    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "NudgeApp")

    private func registerBackgroundTasks() {
        // Strategy 2: reads PendingTriggers from the App Group and calls send-nudge
        // via the reliable main-app network context.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BGTaskIdentifiers.nudgeTrigger,
            using: nil
        ) { task in
            // The handler closure runs off the main actor; hop back on to touch the
            // MainActor-isolated scheduling helper, auth SDK, and service.
            let work = Task { @MainActor in
                // Reschedule immediately so the queue keeps draining over time.
                self.scheduleNudgeTriggerProcessing()

                // Auth session is available at the SDK level without @StateObject.
                guard let userId = supabase.auth.currentUser?.id else {
                    task.setTaskCompleted(success: true)
                    return
                }

                let service = NudgeTriggerService()
                await service.drainPendingTriggers(userId: userId)
                task.setTaskCompleted(success: true)
            }

            task.expirationHandler = {
                work.cancel()
            }
        }
    }

    private func scheduleNudgeTriggerProcessing() {
        let request = BGProcessingTaskRequest(identifier: BGTaskIdentifiers.nudgeTrigger)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NudgeApp.logger.error("failed to schedule nudge-trigger BG task: \(error.localizedDescription, privacy: .public)")
        }
    }
}

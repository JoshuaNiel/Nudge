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
    @Environment(\.scenePhase) private var scenePhase

    // Set when onForeground bails because currentUser was nil (cold start auth race).
    // Cleared once the deferred monitoring registration runs.
    @State private var pendingForegroundSync = false

    private let monitoringService = MonitoringRegistrationService.shared
    private let goalService = GoalService()

    init() {
        registerBackgroundTasks()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(appDelegate.pushRouter)
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
                .alert("Link Expired", isPresented: $authRecovery.isShowingExpiredLinkAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(AuthRecoveryCoordinator.expiredLinkMessage)
                }
                // Password-reset and email-confirmation links (nudge://…).
                .onOpenURL { url in
                    Task { await authRecovery.handleOpenURL(url) }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await onForeground() }
            } else if newPhase == .background {
                // Ask the OS to wake us later to drain any queued nudge triggers.
                scheduleNudgeTriggerProcessing()
            }
        }
        // Auth race recovery: if onForeground bailed because currentUser was nil,
        // run monitoring registration as soon as the user becomes available.
        .onChange(of: appState.currentUser) { _, newUser in
            if newUser != nil && pendingForegroundSync {
                pendingForegroundSync = false
                Task { await onForeground() }
            }
        }
    }

    // MARK: - Foreground handler

    private func onForeground() async {
        guard let userId = appState.currentUser?.id else {
            pendingForegroundSync = true
            return
        }
        pendingForegroundSync = false

        // Never prompts — onboarding's PermissionsView owns the permission request. Re-registering
        // each foreground keeps the stored token fresh (APNs may rotate it).
        await PushRegistration.registerIfAuthorized()

        await refreshMonitoring(userId: userId)

        // Strategy 2: flush any queued nudge triggers now that we're in a reliable
        // (foregrounded) network context. Runs regardless of the outcome above —
        // triggers already on the queue are still worth sending.
        await NudgeTriggerService().drainPendingTriggers(userId: userId)
    }

    /// Re-registers monitoring from freshly fetched goals.
    ///
    /// Both fetches must succeed before touching `DeviceActivityCenter`. A failed
    /// request used to arrive here as an empty goal list, indistinguishable from
    /// "this user has no goals" — which re-registered with zero events and silently
    /// disarmed every trigger until the next successful foreground (ADR-054).
    /// Leaving yesterday's registration in place is strictly safer than replacing it
    /// with one built from data we do not have.
    private func refreshMonitoring(userId: UUID) async {
        guard await appState.fetchAndCacheProfile(userId: userId) else {
            NudgeApp.logger.error("profile fetch failed — leaving existing monitoring registration untouched")
            return
        }
        guard let goals = try? await goalService.fetchGoalSummaries(userId: userId) else {
            NudgeApp.logger.error("goal fetch failed — leaving existing monitoring registration untouched")
            return
        }
        monitoringService.refreshMonitoring(
            goals: goals,
            sessionTimeoutMinutes: appState.sessionTimeoutMinutes
        )
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

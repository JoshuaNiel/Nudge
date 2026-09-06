import SwiftUI
import BackgroundTasks
import os
import Supabase
internal import Auth

@main
struct NudgeApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    // Set when onForeground bails because currentUser was nil (cold start auth race).
    // Cleared once the deferred monitoring registration runs.
    @State private var pendingForegroundSync = false

    private let monitoringService = MonitoringRegistrationService()
    private let goalService = GoalService()

    init() {
        registerBackgroundTasks()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
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

        // Refresh profile so sessionTimeoutMinutes reflects any server-side changes.
        await appState.fetchAndCacheProfile(userId: userId)

        let goals = (try? await goalService.fetchGoalSummaries(userId: userId)) ?? []
        await monitoringService.reregisterIfLapsed(
            goals: goals,
            sessionTimeoutMinutes: appState.sessionTimeoutMinutes
        )

        // Strategy 2: flush any queued nudge triggers now that we're in a reliable
        // (foregrounded) network context.
        await NudgeTriggerService().drainPendingTriggers(userId: userId)
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

import SwiftUI
import BackgroundTasks
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
    }

    // MARK: - Background Tasks

    private func registerBackgroundTasks() {
        // Strategy 2 fallback: reads PendingTriggers from App Group and calls send-nudge.
        // Currently a stub; NudgeTriggerService implementation is Phase 1 remaining work.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BGTaskIdentifiers.nudgeTrigger,
            using: nil
        ) { task in
            task.setTaskCompleted(success: true)
        }
    }
}

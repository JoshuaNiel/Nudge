import Foundation

/// Where a signed-in user goes (docs/specs/onboarding-progress.md §4).
enum OnboardingDestination: Equatable {
    case profileSetup
    /// The permissions screen, showing only these never-asked permissions (may be empty for a
    /// not-yet-completed user who has already answered both; the screen then just finishes).
    case permissions(pending: [DevicePermission])
    case app
}

enum OnboardingRouting {

    /// 1. Account step pending → profile setup.
    /// 2. Not completed, or a permission never asked on this device → permissions screen with
    ///    the `notDetermined` ones. Denied counts as asked (iOS won't re-prompt). Permissions
    ///    the user skipped this session are left out so "Skip for now" lands in the app.
    /// 3. Otherwise → the app.
    static func destination(
        progress: OnboardingProgress,
        screenTime: PermissionStatus,
        notifications: PermissionStatus,
        skipped: Set<DevicePermission>
    ) -> OnboardingDestination {
        if progress.nextStep == .profile { return .profileSetup }

        let statuses: [(DevicePermission, PermissionStatus)] = [
            (.screenTime, screenTime),
            (.notifications, notifications),
        ]
        let pending = statuses
            .filter { $0.1 == .notDetermined && !skipped.contains($0.0) }
            .map(\.0)

        if !progress.completed || !pending.isEmpty { return .permissions(pending: pending) }
        return .app
    }
}

/// Merge rules, device copy ← server (spec §3.3).
enum OnboardingMerge {

    /// - `completed`: device OR server (never goes back to false).
    /// - Names: a queued name update means the device value is newest; otherwise the server's.
    /// - `nextStep`: recomputed from the merged names (mirrors the server function).
    static func merge(
        device: OnboardingProgress?,
        server: OnboardingServerStatus,
        hasQueuedNameUpdate: Bool,
        now: Date
    ) -> OnboardingProgress {
        let keepDeviceName = hasQueuedNameUpdate && device != nil
        let firstName = keepDeviceName ? device?.firstName : server.firstName
        let lastName = keepDeviceName ? device?.lastName : server.lastName
        return OnboardingProgress(
            completed: (device?.completed ?? false) || server.completed,
            nextStep: OnboardingProgress.nextStep(firstName: firstName, lastName: lastName),
            firstName: firstName,
            lastName: lastName,
            updatedAt: now
        )
    }
}

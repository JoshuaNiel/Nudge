import Foundation

/// Keys the main app stores in `UserDefaults.standard` (including via `@AppStorage`).
/// App Group keys shared with extensions live in `AppGroupKeys` instead.
enum AppStorageKeys {
    /// Legacy device-wide "finished onboarding" flag from before per-account onboarding
    /// progress (docs/specs/onboarding-progress.md). Read once to seed a user's device copy,
    /// then deleted. Account deletion also removes it.
    static let onboardingComplete = "onboardingComplete"

    /// The outbox of pending server writes (`Outbox`), all users, oldest first.
    static let outbox = "outbox.pendingWrites"

    /// Device-wide (not per user, never synced): the full-screen permissions page has been
    /// reached on this device, so it is never shown again (`PermissionsPageTracker`,
    /// onboarding-progress spec §5b). Missing only before the first launch of the build that
    /// added it; that launch infers it from existing data and records the answer.
    static let permissionsPageShown = "permissionsPageShown"

    /// Prefix of every user's onboarding device copy key.
    static let onboardingProgressPrefix = "onboarding.progress."

    /// A user's device copy of their onboarding progress (`OnboardingStore`).
    static func onboardingProgress(for userId: UUID) -> String {
        onboardingProgressPrefix + userId.uuidString
    }
}

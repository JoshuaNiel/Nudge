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

    /// A user's device copy of their onboarding progress (`OnboardingStore`).
    static func onboardingProgress(for userId: UUID) -> String {
        "onboarding.progress.\(userId.uuidString)"
    }
}

import Foundation

/// Keys the main app stores in `UserDefaults.standard` (including via `@AppStorage`).
/// App Group keys shared with extensions live in `AppGroupKeys` instead.
enum AppStorageKeys {
    /// Set when the user finishes onboarding; reset by account deletion.
    static let onboardingComplete = "onboardingComplete"
}

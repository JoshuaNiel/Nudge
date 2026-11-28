import Foundation
import Combine

/// The full-screen permissions page appears at most once per device
/// (docs/specs/onboarding-progress.md §5b). After that, the permission banners and the
/// in-context asks cover anything still off.
///
/// Device-wide, in standard `UserDefaults` (not per user, never synced): a reinstall or a new
/// device counts as new.
@MainActor
final class PermissionsPageTracker: ObservableObject {

    /// True once the page is over on this device: it was reached on an earlier launch (or
    /// inferred for an existing device), or it finished this launch. Routing never shows the
    /// page again once this is true.
    @Published private(set) var isFinished: Bool

    private let defaults: UserDefaults

    // Production init — standard defaults; any completed onboarding copy on the device.
    convenience init() {
        self.init(defaults: .standard, hasCompletedDeviceCopy: { OnboardingStore().hasAnyCompletedCopy() })
    }

    /// Reads the flag. When it was never recorded (the first launch of this build), infers it
    /// from existing data and records the answer, so the inference runs once per device.
    ///
    /// Must be created before `OnboardingProgressController.prepare` runs, because that deletes
    /// the legacy flag the inference reads (both are app-level `@StateObject`s, created before
    /// `RootView`'s tasks run).
    init(defaults: UserDefaults, hasCompletedDeviceCopy: () -> Bool) {
        self.defaults = defaults
        let shown: Bool
        if let recorded = defaults.object(forKey: AppStorageKeys.permissionsPageShown) as? Bool {
            shown = recorded
        } else {
            shown = Self.inferShown(
                legacyOnboardingComplete: defaults.bool(forKey: AppStorageKeys.onboardingComplete),
                completedDeviceCopy: hasCompletedDeviceCopy()
            )
            defaults.set(shown, forKey: AppStorageKeys.permissionsPageShown)
        }
        self.isFinished = shown
    }

    /// An existing device (it finished onboarding on an older build, or has a completed device
    /// copy) has already seen the page.
    static func inferShown(legacyOnboardingComplete: Bool, completedDeviceCopy: Bool) -> Bool {
        legacyOnboardingComplete || completedDeviceCopy
    }

    /// The page is on screen: record it, so it never shows again on a later launch. It stays up
    /// for this launch until `finish()`.
    func markReached() {
        defaults.set(true, forKey: AppStorageKeys.permissionsPageShown)
    }

    /// The user answered or skipped everything on the page.
    func finish() {
        markReached()
        if !isFinished { isFinished = true }
    }
}

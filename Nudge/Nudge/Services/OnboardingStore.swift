import Foundation

/// The device copy of onboarding progress, one entry per user.
protocol OnboardingProgressStoring: AnyObject {
    func load(for userId: UUID) -> OnboardingProgress?
    func save(_ progress: OnboardingProgress, for userId: UUID)
    func remove(for userId: UUID)
}

/// Stores each user's copy as JSON in standard `UserDefaults`, keyed by user id. Kept on
/// sign-out (a re-sign-in on this device works offline); removed on account deletion.
final class OnboardingStore: OnboardingProgressStoring {
    private let defaults: UserDefaults

    init() { self.defaults = .standard }

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load(for userId: UUID) -> OnboardingProgress? {
        guard let data = defaults.data(forKey: AppStorageKeys.onboardingProgress(for: userId)) else { return nil }
        return try? JSONDecoder().decode(OnboardingProgress.self, from: data)
    }

    func save(_ progress: OnboardingProgress, for userId: UUID) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: AppStorageKeys.onboardingProgress(for: userId))
    }

    func remove(for userId: UUID) {
        defaults.removeObject(forKey: AppStorageKeys.onboardingProgress(for: userId))
    }

    /// Whether any user's copy on this device says onboarding is completed. Used once, to
    /// recognize an existing device when `permissionsPageShown` was never recorded.
    func hasAnyCompletedCopy() -> Bool {
        let decoder = JSONDecoder()
        return defaults.dictionaryRepresentation().contains { key, value in
            guard key.hasPrefix(AppStorageKeys.onboardingProgressPrefix), let data = value as? Data else { return false }
            return (try? decoder.decode(OnboardingProgress.self, from: data))?.completed == true
        }
    }
}

// MARK: - Account deletion

/// Removes a user's on-device data that isn't in the App Group (account deletion).
protocol UserLocalDataClearing {
    func clearLocalData(for userId: UUID)
}

/// Clears the user's onboarding copy and their queued outbox writes.
@MainActor
struct OnboardingLocalDataClearer: UserLocalDataClearing {
    private let store: OnboardingProgressStoring
    private let outbox: Outbox

    init() {
        self.store = OnboardingStore()
        self.outbox = .shared
    }

    init(store: OnboardingProgressStoring, outbox: Outbox) {
        self.store = store
        self.outbox = outbox
    }

    func clearLocalData(for userId: UUID) {
        store.remove(for: userId)
        outbox.removeAll(for: userId)
    }
}

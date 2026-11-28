import Foundation
import DeviceActivity
import Supabase
import os

// MARK: - Protocols

/// Local cleanup that runs only after the server has confirmed the account is deleted.
protocol AccountCleanupProtocol {
    func performPostDeletionCleanup() async
}

/// Stops every DeviceActivity schedule this app registered.
protocol MonitoringStopping {
    func stopAllMonitoring()
}

/// Ends the Supabase session on this device only.
protocol LocalSessionEnding {
    /// Must clear the local session even if the network call fails (the server user is gone).
    func endLocalSession() async
}

// MARK: - Service

/// Puts the device back into a fresh-install state for the next account.
///
/// Order matters:
/// 1. Stop monitoring first, so the monitor extension cannot fire (and try to text a
///    friend with a dead JWT) or re-register from the App Group mid-wipe.
/// 2. Wipe the App Group — JWT, anon key, friends, goals, pending triggers, registration
///    stamps and FamilyActivitySelection blobs — so nothing of the deleted user remains for
///    the extension to read.
/// 3. Remove the deleted user's on-device data outside the App Group: their onboarding
///    progress copy and their queued outbox writes (read the user id before the session ends).
///    Also remove the legacy device-wide `onboardingComplete` flag, if an old build left one.
/// 4. End the session last. That emits `.signedOut`, which flips `AppState` to
///    unauthenticated (and resets `PushTokenManager`'s in-memory upload state); RootView
///    then shows the auth flow.
///
/// Deliberately kept: the device's APNs token in standard defaults (device-scoped — the next
/// account to sign in needs it; its `device_tokens` row already cascaded server-side) and the
/// Family Controls authorization (a device permission, not account data).
@MainActor
final class AccountCleanupService: AccountCleanupProtocol {

    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "AccountCleanup")

    private let monitoring: MonitoringStopping
    private let appGroupSuiteName: String
    private let appGroupDefaults: UserDefaults?
    private let appStorage: UserDefaults
    private let userLocalData: UserLocalDataClearing
    private let currentUserId: () -> UUID?
    private let session: LocalSessionEnding

    // Production init — real DeviceActivityCenter, App Group suite, and Supabase session.
    init() {
        self.monitoring = DeviceActivityMonitoringStopper()
        self.appGroupSuiteName = AppGroupKeys.suiteName
        self.appGroupDefaults = UserDefaults(suiteName: AppGroupKeys.suiteName)
        self.appStorage = .standard
        self.userLocalData = OnboardingLocalDataClearer()
        self.currentUserId = { supabase.auth.currentUser?.id }
        self.session = SupabaseLocalSession()
    }

    // Test init — mocks and isolated defaults suites.
    init(
        monitoring: MonitoringStopping,
        appGroupSuiteName: String,
        appGroupDefaults: UserDefaults?,
        appStorage: UserDefaults,
        userLocalData: UserLocalDataClearing,
        currentUserId: @escaping () -> UUID?,
        session: LocalSessionEnding
    ) {
        self.monitoring = monitoring
        self.appGroupSuiteName = appGroupSuiteName
        self.appGroupDefaults = appGroupDefaults
        self.appStorage = appStorage
        self.userLocalData = userLocalData
        self.currentUserId = currentUserId
        self.session = session
    }

    func performPostDeletionCleanup() async {
        monitoring.stopAllMonitoring()
        wipeAppGroup()
        if let userId = currentUserId() {
            userLocalData.clearLocalData(for: userId)
        }
        appStorage.removeObject(forKey: AppStorageKeys.onboardingComplete)
        await session.endLocalSession()
    }

    /// Removes the whole App Group domain rather than a hand-maintained key list, so keys
    /// added later (or dynamic ones like `nudge.selection.app.<bundleId>`) can't be missed.
    private func wipeAppGroup() {
        guard let defaults = appGroupDefaults else { return }
        defaults.removePersistentDomain(forName: appGroupSuiteName)

        // Belt and braces: `removePersistentDomain` has historically been unreliable for
        // App Group suites on some iOS versions. Remove anything still present key by key.
        // (`persistentDomain` lists only this suite's own keys — not NSGlobalDomain.)
        let leftovers = defaults.persistentDomain(forName: appGroupSuiteName) ?? [:]
        for key in leftovers.keys {
            defaults.removeObject(forKey: key)
        }
        if !leftovers.isEmpty {
            Self.logger.notice("App Group needed per-key removal for \(leftovers.count) key(s)")
        }
    }
}

// MARK: - Production adapters

/// Stops all of this app's DeviceActivity schedules (today only `MonitoringPlan.activityName`).
struct DeviceActivityMonitoringStopper: MonitoringStopping {
    func stopAllMonitoring() {
        // An empty list stops every activity this app has registered.
        DeviceActivityCenter().stopMonitoring()
    }
}

/// Clears the Supabase session from this device.
@MainActor
struct SupabaseLocalSession: LocalSessionEnding {
    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "AccountCleanup")

    func endLocalSession() async {
        // `.local` scope: the SDK removes the stored session and emits `.signedOut` *before*
        // calling /logout, and ignores the 401/403/404 a deleted user gets back — so the
        // device is signed out even if the request fails. Any other error (e.g. offline) is
        // only logged: the local session is already gone at that point.
        do {
            try await supabase.auth.signOut(scope: .local)
        } catch {
            Self.logger.notice("remote logout after deletion failed (local session already cleared): \(error.localizedDescription, privacy: .public)")
        }
    }
}

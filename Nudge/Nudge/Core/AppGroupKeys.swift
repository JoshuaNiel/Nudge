import Foundation

/// All App Group UserDefaults keys and the shared suite name.
/// Both the main app target and extension targets must enroll in `suiteName`.
enum AppGroupKeys {

    static let suiteName = "group.com.joshuaqn.Nudge"

    // MARK: - Auth (main app → extensions)
    static let supabaseUrl = "nudge.auth.supabaseUrl"
    static let anonKey     = "nudge.auth.anonKey"
    static let jwt         = "nudge.auth.jwt"

    // MARK: - User (main app → extensions)
    static let userFirstName = "nudge.user.firstName"

    // MARK: - Goals (main app → DeviceActivityMonitor extension)
    static let goalsActive = "nudge.goals.active"

    // MARK: - Friends (main app → DeviceActivityMonitor extension)
    /// JSON-encoded [FriendSummary] of accepted friends.
    static let friendsAccepted = "nudge.friends.accepted"

    // MARK: - Triggers (Strategy 2 fallback: monitor extension → main app)
    static let triggersPending = "nudge.triggers.pending"

    // MARK: - Monitoring config snapshot (main app — used to detect changes)
    /// The session_timeout_minutes value that was in effect during the last
    /// successful startMonitoring call. Compared on every foreground so that
    /// profile changes cause a fresh registration without requiring a device restart.
    static let lastRegisteredTimeout = "nudge.monitoring.lastTimeout"

    // MARK: - Sync flags
    /// Set by DeviceActivityMonitor.intervalDidEnd; cleared by main app on next foreground.
    static let midnightSyncNeeded = "nudge.sync.midnightNeeded"

    // MARK: - FamilyActivitySelection storage (main app → MonitoringRegistrationService)
    // Stored as PropertyList-encoded FamilyActivitySelection.
    // Written when the user picks an app goal target via FamilyActivityPicker (Phase 3).
    static func appSelectionKey(_ bundleId: String) -> String {
        "nudge.selection.app.\(bundleId)"
    }
    static func categorySelectionKey(_ categoryId: Int) -> String {
        "nudge.selection.category.\(categoryId)"
    }
}

// MARK: - Background Task Identifiers

/// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
enum BGTaskIdentifiers {
    static let nudgeTrigger = "com.joshuaqn.Nudge.nudge-trigger"
}

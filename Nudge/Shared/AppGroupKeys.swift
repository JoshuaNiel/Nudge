import Foundation

/// All App Group UserDefaults keys and the shared suite name.
/// Both the main app target and extension targets must enroll in `suiteName`.
///
/// Compiled into both the `Nudge` app target and the `NudgeActivityMonitor`
/// extension target (see the `Shared/` synchronized folder), so the two sides
/// cannot drift apart.
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

    // MARK: - Monitoring registration stamps (written by MonitoringPlan.register)
    /// Local calendar day ("yyyy-MM-dd") of the last successful startMonitoring call.
    /// DeviceActivityEvent thresholds do not reliably re-arm across a repeating
    /// daily interval, so a change of day forces a fresh registration (ADR-054).
    static let lastRegisteredDay = "nudge.monitoring.lastDay"

    /// Signature of the GoalSummary set used for the last successful startMonitoring
    /// call. A change means the user's goals or session timeout were edited.
    static let lastRegisteredSignature = "nudge.monitoring.lastSignature"

    // MARK: - Fired-event dedup (written by the monitor extension via FiredEventStore)
    /// Prefix of the per-day fired-event records. `FiredEventStore.prune` deletes
    /// only keys under this prefix, so nothing else may use it.
    static let firedKeyPrefix = "nudge.fired."

    /// JSON-encoded sorted `[String]` of dedup keys (`"<eventName>@<thresholdSeconds>"`)
    /// whose side effects already ran on `day` ("yyyy-MM-dd", local). Needed because
    /// events count past activity, so an already-passed threshold fires again on
    /// every mid-day re-registration (ADR-054 amendment).
    static func firedKey(day: String) -> String {
        "\(firedKeyPrefix)\(day)"
    }

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

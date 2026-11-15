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
    /// JSON-encoded [GoalSummary]: the full, *unfiltered* monitored catalog (all goals +
    /// the session-timeout pseudo-goal). `MonitoringPlan` filters it to today's active
    /// set at each registration. The key name predates the catalog and is kept so App
    /// Group data from earlier versions is still found.
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

    // MARK: - Sync flags
    /// Set by DeviceActivityMonitor.intervalDidEnd; cleared by main app on next foreground.
    static let midnightSyncNeeded = "nudge.sync.midnightNeeded"

    // MARK: - Goal progress + dedup (monitor extension → main app), Phase 3 G4
    // Day-scoped by the local calendar day ("yyyy-MM-dd"); pruned by GoalProgressStore.
    static let progressKeyPrefix = "nudge.progress."
    static let firedKeyPrefix    = "nudge.fired."

    /// JSON `{"<goalId>": highestPercent}` for `day`. Written by the monitor extension,
    /// read by the app's Goals list.
    static func progressKey(day: String) -> String { progressKeyPrefix + day }

    /// JSON `[eventName]` of milestone/session events whose side effects already ran on
    /// `day`. Read and written by the monitor extension only.
    static func firedKey(day: String) -> String { firedKeyPrefix + day }

    // MARK: - Why-reminders (main app → monitor extension), Phase 4
    /// JSON `{"<goalId>": {"<percent>": [message]}}`. Written by the main app on every
    /// foreground (after a successful fetch) and after every reminder edit. Deliberately
    /// **not** part of the monitoring signature: editing a why never re-registers.
    static let remindersByGoal = "nudge.reminders.byGoal"

    /// JSON `{"<goalId>.<percent>": nextIndex}` — round-robin position per (goal,
    /// percent). Read and written by the monitor extension only.
    static let remindersRoundRobin = "nudge.reminders.rr"
}

// MARK: - Background Task Identifiers

/// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
enum BGTaskIdentifiers {
    static let nudgeTrigger = "com.joshuaqn.Nudge.nudge-trigger"
}

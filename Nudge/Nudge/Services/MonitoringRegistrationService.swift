import Foundation
import DeviceActivity
import FamilyControls

/// Owns all `DeviceActivityCenter` registration for Nudge.
///
/// Responsibilities:
/// - `registerMonitoring` — builds the full DeviceActivityEvent set from GoalSummaries
///   and calls `DeviceActivityCenter.shared.startMonitoring`.
/// - `reregisterIfLapsed` — called on every app foreground; re-registers if the
///   activity list is empty (covers device restarts).
/// - `goalDidChange` — debounced 10 s; re-registers after the user stops editing goals.
///
/// **Note on app-specific goals (Phase 3 dependency):**
/// Creating a `DeviceActivityEvent` for a specific app requires an `ApplicationToken`,
/// which can only be obtained via `FamilyActivityPicker`. Until Phase 3 implements
/// the picker and stores selections to App Group, app-specific and category-specific
/// goals are skipped during registration. Only `total` and `session.timeout` events
/// are registered in Phase 1.
@MainActor
class MonitoringRegistrationService {

    private let center = DeviceActivityCenter()
    private var debounceTask: Task<Void, Never>?

    static let activityName = DeviceActivityName("nudge.daily")

    // MARK: - Public interface

    /// Registers (or re-registers) monitoring for all provided goals.
    /// Also writes the active GoalSummary list to App Group so the monitor extension
    /// can compose nudge messages without a Supabase call.
    func registerMonitoring(goals: [GoalSummary], sessionTimeoutMinutes: Int?) throws {
        // Stop existing monitoring before re-registering
        center.stopMonitoring([Self.activityName])

        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0, second: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59, second: 59),
            repeats: true
        )

        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]

        // Register an event for each goal
        for summary in goals {
            if let event = buildEvent(for: summary) {
                events[DeviceActivityEvent.Name(summary.eventName)] = event
            }
        }

        // Register the session timeout event (if configured)
        if let minutes = sessionTimeoutMinutes, minutes > 0 {
            let timeoutSummary = GoalSummary(
                goalId: 0,
                eventName: "session.timeout",
                limitSeconds: minutes * 60,
                targetLabel: "Session",
                appBundleId: nil
            )
            if let event = buildEvent(for: timeoutSummary) {
                events[DeviceActivityEvent.Name("session.timeout")] = event
            }
        }

        // Register the schedule even when events is empty — an empty events dict is valid
        // and is required so that DeviceActivityReport has a monitored period to query.
        try center.startMonitoring(Self.activityName, during: schedule, events: events)
        print("[MonitoringService] startMonitoring succeeded, \(events.count) events registered")

        // Persist the timeout value so reregisterIfLapsed can detect profile changes.
        let defaults = UserDefaults(suiteName: AppGroupKeys.suiteName)
        defaults?.set(sessionTimeoutMinutes ?? 0, forKey: AppGroupKeys.lastRegisteredTimeout)

        // Persist summaries + session timeout to App Group for the monitor extension
        persistGoalSummaries(goals: goals, sessionTimeoutMinutes: sessionTimeoutMinutes)
    }

    /// Re-registers monitoring if it has lapsed (device restart) or if the
    /// session timeout setting has changed since the last registration.
    /// Call this on every app foreground.
    func reregisterIfLapsed(goals: [GoalSummary], sessionTimeoutMinutes: Int?) async {
        let activeActivities = center.activities
        let lastTimeout = UserDefaults(suiteName: AppGroupKeys.suiteName)?
            .integer(forKey: AppGroupKeys.lastRegisteredTimeout) ?? 0
        let currentTimeout = sessionTimeoutMinutes ?? 0
        let configChanged = currentTimeout != lastTimeout

        print("[MonitoringService] reregisterIfLapsed — active: \(activeActivities.count), lastTimeout: \(lastTimeout)m, currentTimeout: \(currentTimeout)m, configChanged: \(configChanged)")

        guard activeActivities.isEmpty || configChanged else { return }
        do {
            try registerMonitoring(goals: goals, sessionTimeoutMinutes: sessionTimeoutMinutes)
        } catch {
            print("[MonitoringService] startMonitoring failed: \(error)")
        }
    }

    /// Debounced 10 s re-registration. Call whenever goal data changes.
    func goalDidChange(goals: [GoalSummary], sessionTimeoutMinutes: Int?) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            try? registerMonitoring(goals: goals, sessionTimeoutMinutes: sessionTimeoutMinutes)
        }
    }

    // MARK: - Private helpers

    /// Builds a `DeviceActivityEvent` from a `GoalSummary`.
    /// Returns `nil` for goal types that require a `FamilyActivitySelection`
    /// not yet stored in App Group (app-specific and category goals — Phase 3).
    private func buildEvent(for summary: GoalSummary) -> DeviceActivityEvent? {
        let threshold = secondsToDateComponents(summary.limitSeconds)

        if summary.eventName == "total" || summary.eventName == "session.timeout" {
            // Total/session events cover all apps — no token sets needed
            return DeviceActivityEvent(
                applications: [],
                categories: [],
                webDomains: [],
                threshold: threshold
            )
        }

        if summary.eventName.hasPrefix("app.") || summary.eventName.hasPrefix("category.") {
            // App-specific and category monitoring requires ApplicationToken, which can only
            // be obtained via FamilyActivityPicker (Phase 3). Registering events for these
            // goal types is deferred until Phase 3 stores FamilyActivitySelection to App Group
            // and GoalSummary is extended to carry the selected tokens.
            return nil
        }

        return nil
    }

    private func secondsToDateComponents(_ seconds: Int) -> DateComponents {
        DateComponents(hour: seconds / 3600, minute: (seconds % 3600) / 60, second: seconds % 60)
    }

    private func persistGoalSummaries(goals: [GoalSummary], sessionTimeoutMinutes: Int?) {
        var allSummaries = goals

        if let minutes = sessionTimeoutMinutes, minutes > 0 {
            allSummaries.append(GoalSummary(
                goalId: 0,
                eventName: "session.timeout",
                limitSeconds: minutes * 60,
                targetLabel: "Session",
                appBundleId: nil
            ))
        }

        guard let data = try? JSONEncoder().encode(allSummaries) else { return }
        UserDefaults(suiteName: AppGroupKeys.suiteName)?.set(data, forKey: AppGroupKeys.goalsActive)
    }
}

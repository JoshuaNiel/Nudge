import Foundation
import DeviceActivity
import FamilyControls

/// Main-app owner of `DeviceActivityCenter` registration.
///
/// The monitoring rules themselves live in `MonitoringPlan` (in `Shared/`, compiled
/// into the monitor extension too) — this type is the app-side entry point plus the
/// debounce for in-app goal edits.
///
/// **The app is a safety net, not the primary re-arm path.** Monitoring must keep
/// working with the app never opened, so the monitor extension re-registers itself
/// at `intervalDidStart` (ADR-054). `refreshMonitoring` covers the cases the
/// extension cannot: a device restart that cleared all activities, and a day
/// rollover the extension somehow missed.
@MainActor
class MonitoringRegistrationService {

    private let center = DeviceActivityCenter()
    private var debounceTask: Task<Void, Never>?

    static var activityName: DeviceActivityName { MonitoringPlan.activityName }

    // MARK: - Public interface

    /// Unconditionally registers monitoring for the given goals.
    ///
    /// Callers must pass data they actually fetched — never an empty array standing
    /// in for a failed request, which would silently disarm every trigger.
    func registerMonitoring(goals: [GoalSummary], sessionTimeoutMinutes: Int?) throws {
        let summaries = MonitoringPlan.composeSummaries(
            goals: goals,
            sessionTimeoutMinutes: sessionTimeoutMinutes
        )
        let count = try MonitoringPlan.register(
            summaries: summaries,
            center: center,
            defaults: UserDefaults(suiteName: AppGroupKeys.suiteName),
            now: Date(),
            calendar: .current
        )
        print("[MonitoringService] startMonitoring succeeded, \(count) events registered")
    }

    /// Foreground entry point. Re-registers only when something makes the current
    /// registration stale: monitoring lapsed, the calendar day rolled over, or the
    /// goal set changed. Returns whether a registration actually happened.
    @discardableResult
    func refreshMonitoring(
        goals: [GoalSummary],
        sessionTimeoutMinutes: Int?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        let defaults = UserDefaults(suiteName: AppGroupKeys.suiteName)
        let summaries = MonitoringPlan.composeSummaries(
            goals: goals,
            sessionTimeoutMinutes: sessionTimeoutMinutes
        )
        let today = MonitoringPlan.dayStamp(for: now, calendar: calendar)
        let signature = MonitoringPlan.signature(for: summaries)

        let needed = MonitoringPlan.shouldRegister(
            isMonitoringActive: !center.activities.isEmpty,
            lastDay: defaults?.string(forKey: AppGroupKeys.lastRegisteredDay),
            lastSignature: defaults?.string(forKey: AppGroupKeys.lastRegisteredSignature),
            today: today,
            signature: signature
        )

        print("""
        [MonitoringService] refreshMonitoring — active: \(center.activities.count), \
        today: \(today), lastDay: \(defaults?.string(forKey: AppGroupKeys.lastRegisteredDay) ?? "nil"), \
        needed: \(needed)
        """)

        guard needed else { return false }

        do {
            try registerMonitoring(goals: goals, sessionTimeoutMinutes: sessionTimeoutMinutes)
            return true
        } catch {
            print("[MonitoringService] startMonitoring failed: \(error)")
            return false
        }
    }

    /// Debounced 10 s re-registration. Call whenever goal data changes so an edit
    /// takes effect without waiting for the next foreground.
    func goalDidChange(goals: [GoalSummary], sessionTimeoutMinutes: Int?) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            try? registerMonitoring(goals: goals, sessionTimeoutMinutes: sessionTimeoutMinutes)
        }
    }
}

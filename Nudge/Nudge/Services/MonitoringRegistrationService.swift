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
/// What a foreground `refreshMonitoring` did. `PermissionStatusStore` reads it for the one
/// Screen Time signal FamilyControls doesn't give the app directly (see `isScreenTimeUnauthorized`).
enum MonitoringRefreshOutcome {
    /// The current registration is fresh; `DeviceActivityCenter` was not called.
    case notNeeded
    /// `startMonitoring` succeeded. Clears an `.unauthorized` denial, but is not proof of
    /// access on its own: on device it also succeeds right after a revoke (finding B).
    case registered
    /// `startMonitoring` threw. The error is passed through unchanged from `DeviceActivityCenter`.
    case failed(Error)

    /// True only for `DeviceActivityCenter.MonitoringError.unauthorized`, the error
    /// `startMonitoring` throws once the user revokes Nudge's Screen Time access.
    ///
    /// This compensates for FamilyControls caching the authorization status per process:
    /// after a revoke in Settings, `AuthorizationCenter.shared.authorizationStatus` (and its
    /// publisher) keep reporting `.approved` until the app is relaunched, while monitoring
    /// already fails. Matched exactly: other monitoring errors (bad schedule, too many
    /// activities) and other "not authorized" errors (e.g. the report's
    /// `UsageTrackingErrorDomain` fetch error) say nothing reliable about the permission.
    var isScreenTimeUnauthorized: Bool {
        guard case .failed(let error) = self,
              let monitoringError = error as? DeviceActivityCenter.MonitoringError else { return false }
        return monitoringError == .unauthorized
    }
}

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

    /// Whether monitoring registered earlier today is gone, the on-device sign that Screen
    /// Time access was removed (see `MonitoringPlan.activitiesLapsedSinceRegisteringToday`).
    /// Local reads only, so the foreground refresh checks it before any network fetch and an
    /// offline foreground still detects a revoke.
    func activitiesLapsedSinceRegisteringToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let defaults = UserDefaults(suiteName: AppGroupKeys.suiteName)
        return MonitoringPlan.activitiesLapsedSinceRegisteringToday(
            isMonitoringActive: !center.activities.isEmpty,
            lastDay: defaults?.string(forKey: AppGroupKeys.lastRegisteredDay),
            today: MonitoringPlan.dayStamp(for: now, calendar: calendar)
        )
    }

    /// Foreground entry point. Re-registers only when something makes the current
    /// registration stale: monitoring lapsed, the calendar day rolled over, or the
    /// goal set changed. `force` skips that check (an in-app Screen Time approval: after a
    /// revoke the stamps can look fresh while the registration is not). Returns what
    /// happened, so the caller can report an unauthorized failure to `PermissionStatusStore`.
    ///
    /// A revoked Screen Time permission clears every activity, so `needed` is true and this
    /// attempts one registration per foreground. That is bounded: `register` restores the
    /// stamps on failure and nothing retries until the next foreground.
    @discardableResult
    func refreshMonitoring(
        goals: [GoalSummary],
        sessionTimeoutMinutes: Int?,
        force: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> MonitoringRefreshOutcome {
        let defaults = UserDefaults(suiteName: AppGroupKeys.suiteName)
        let summaries = MonitoringPlan.composeSummaries(
            goals: goals,
            sessionTimeoutMinutes: sessionTimeoutMinutes
        )
        let today = MonitoringPlan.dayStamp(for: now, calendar: calendar)
        let signature = MonitoringPlan.signature(for: summaries)
        // One read each: `activities` asks the system, and the stamps are App Group reads.
        let activeCount = center.activities.count
        let lastDay = defaults?.string(forKey: AppGroupKeys.lastRegisteredDay)

        let needed = force || MonitoringPlan.shouldRegister(
            isMonitoringActive: activeCount > 0,
            lastDay: lastDay,
            lastSignature: defaults?.string(forKey: AppGroupKeys.lastRegisteredSignature),
            today: today,
            signature: signature
        )

        print("""
        [MonitoringService] refreshMonitoring — active: \(activeCount), \
        today: \(today), lastDay: \(lastDay ?? "nil"), force: \(force), needed: \(needed)
        """)

        guard needed else { return .notNeeded }

        do {
            try registerMonitoring(goals: goals, sessionTimeoutMinutes: sessionTimeoutMinutes)
            return .registered
        } catch {
            print("[MonitoringService] startMonitoring failed: \(error)")
            return .failed(error)
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

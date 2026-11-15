import Foundation
import DeviceActivity
import FamilyControls
import Supabase
import os

// MARK: - Monitoring inputs

/// Everything a registration is built from. Only ever constructed from data that was
/// actually fetched (ADR-055).
struct MonitoringInputs: Equatable {
    let goals: [GoalSummary]
    let sessionTimeoutMinutes: Int?
}

protocol MonitoringInputsLoading {
    /// Fetches fresh goal summaries and the session timeout. Throws on any failure —
    /// never returns a partial or empty stand-in.
    func loadMonitoringInputs() async throws -> MonitoringInputs
}

/// Production loader: the signed-in user's goals + their `nudge_settings` session timeout
/// (Phase 5E — `profile.session_timeout_minutes` is deprecated and no longer read).
///
/// A failed settings fetch fails the whole load. It is never replaced by
/// `NudgeSettings.defaults`, which would re-register with a session timeout the user may
/// have turned off (ADR-055). A user with *no row* gets the defaults, by design.
@MainActor
final class SupabaseMonitoringInputsLoader: MonitoringInputsLoading {

    enum LoadError: Error { case notSignedIn }

    private let goalService: GoalServiceProtocol
    private let settingsService: NudgeSettingsServiceProtocol
    private let currentUserId: () -> UUID?

    // Production init (ADR-028 two-init pattern).
    init() {
        self.goalService = GoalService()
        self.settingsService = NudgeSettingsService()
        self.currentUserId = { supabase.auth.currentUser?.id }
    }

    init(
        goalService: GoalServiceProtocol,
        settingsService: NudgeSettingsServiceProtocol,
        currentUserId: @escaping () -> UUID?
    ) {
        self.goalService = goalService
        self.settingsService = settingsService
        self.currentUserId = currentUserId
    }

    func loadMonitoringInputs() async throws -> MonitoringInputs {
        guard let userId = currentUserId() else { throw LoadError.notSignedIn }

        let settings = try await settingsService.fetch(userId: userId)
        let goals = try await goalService.fetchGoalSummaries(userId: userId)

        return MonitoringInputs(goals: goals, sessionTimeoutMinutes: settings.effectiveSessionTimeoutMinutes)
    }
}

// MARK: - Protocol

/// What feature ViewModels need: "goal data changed, re-arm monitoring soon".
protocol MonitoringRegistrationServiceProtocol: AnyObject {
    func goalDidChange()
}

// MARK: - Service

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
///
/// Use `shared` so every screen's `goalDidChange()` calls fall into one debounce window.
@MainActor
final class MonitoringRegistrationService: MonitoringRegistrationServiceProtocol {

    static let shared = MonitoringRegistrationService()

    /// ADR-035 / Phase 3 G9.
    static let goalChangeDebounce: Duration = .milliseconds(1500)

    private let center = DeviceActivityCenter()
    private let inputsLoader: MonitoringInputsLoading
    private let debounce: Duration
    private let sleep: (Duration) async throws -> Void
    private let applyOverride: ((MonitoringInputs) -> Void)?
    private var debounceTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "MonitoringService")

    static var activityName: DeviceActivityName { MonitoringPlan.activityName }

    // Production init (ADR-028 two-init pattern).
    init() {
        self.inputsLoader = SupabaseMonitoringInputsLoader()
        self.debounce = Self.goalChangeDebounce
        self.sleep = { try await Task.sleep(for: $0) }
        self.applyOverride = nil
    }

    /// Test init. `apply` replaces `refreshMonitoring` so no `DeviceActivityCenter` call
    /// is made; `sleep` must throw on cancellation, as `Task.sleep` does.
    init(
        inputsLoader: MonitoringInputsLoading,
        debounce: Duration,
        sleep: @escaping (Duration) async throws -> Void,
        apply: @escaping (MonitoringInputs) -> Void
    ) {
        self.inputsLoader = inputsLoader
        self.debounce = debounce
        self.sleep = sleep
        self.applyOverride = apply
    }

    // MARK: - Public interface

    /// Unconditionally registers monitoring for the given goals.
    ///
    /// Callers must pass data they actually fetched — never an empty array standing in
    /// for a failed request, which would silently disarm every trigger.
    func registerMonitoring(goals: [GoalSummary], sessionTimeoutMinutes: Int?) throws {
        let count = try MonitoringPlan.register(
            catalog: MonitoringPlan.catalog(goals: goals, sessionTimeoutMinutes: sessionTimeoutMinutes),
            center: center,
            defaults: UserDefaults(suiteName: AppGroupKeys.suiteName),
            now: Date(),
            calendar: .current
        )
        logger.log("startMonitoring succeeded, \(count) events registered")
    }

    /// Foreground / goal-change entry point. Always refreshes the App Group catalog from
    /// the freshly fetched data, then re-registers only when something makes the current
    /// registration stale: monitoring lapsed, the calendar day rolled over, or today's
    /// active set or the daily-report toggle changed. Returns whether a registration
    /// actually happened. The toggle is read from the App Group settings, which callers
    /// write before getting here (`fetchAndCacheNudgeSettings`, Settings save).
    ///
    /// Persisting the catalog even when no registration is needed keeps the extension's
    /// midnight re-arm current (e.g. a temporary goal that starts tomorrow) without
    /// resetting today's counters.
    @discardableResult
    func refreshMonitoring(
        goals: [GoalSummary],
        sessionTimeoutMinutes: Int?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        let defaults = UserDefaults(suiteName: AppGroupKeys.suiteName)
        let catalog = MonitoringPlan.catalog(goals: goals, sessionTimeoutMinutes: sessionTimeoutMinutes)
        MonitoringPlan.persistCatalog(catalog, defaults: defaults)

        let today = MonitoringPlan.dayStamp(for: now, calendar: calendar)
        // Includes the daily-report toggle from the App Group settings (Phase 5E-2) —
        // the same source the extension's re-arm uses, so the two always agree.
        let signature = MonitoringPlan.registrationSignature(
            catalog: catalog, defaults: defaults, now: now, calendar: calendar
        )
        let lastDay = defaults?.string(forKey: AppGroupKeys.lastRegisteredDay)

        let needed = MonitoringPlan.shouldRegister(
            isMonitoringActive: !center.activities.isEmpty,
            lastDay: lastDay,
            lastSignature: defaults?.string(forKey: AppGroupKeys.lastRegisteredSignature),
            today: today,
            signature: signature
        )

        logger.log("refreshMonitoring — active: \(self.center.activities.count), today: \(today, privacy: .public), lastDay: \(lastDay ?? "nil", privacy: .public), needed: \(needed)")

        guard needed else { return false }

        do {
            try registerMonitoring(goals: goals, sessionTimeoutMinutes: sessionTimeoutMinutes)
            return true
        } catch {
            logger.error("startMonitoring failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Call after any successful goal or category create/edit/delete, or nudge-settings
    /// save (Phase 5E — a session-timeout change re-arms through here). Debounced 1.5 s
    /// (ADR-035): each call restarts the timer, and only the last one fetches fresh goals
    /// + session timeout and refreshes monitoring. A failed fetch leaves the existing
    /// registration untouched (ADR-055); the next foreground retries.
    func goalDidChange() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(self.debounce)
            } catch {
                return   // cancelled by a newer change
            }
            guard !Task.isCancelled else { return }

            let inputs: MonitoringInputs
            do {
                inputs = try await self.inputsLoader.loadMonitoringInputs()
            } catch {
                self.logger.error("goalDidChange: fetch failed — leaving monitoring untouched: \(error.localizedDescription, privacy: .public)")
                return
            }
            // A newer change arrived while fetching; its own task will register.
            guard !Task.isCancelled else { return }
            self.apply(inputs)
        }
    }

    /// Awaits the in-flight debounced registration, if any. Used by tests.
    func waitForPendingGoalChange() async {
        await debounceTask?.value
    }

    private func apply(_ inputs: MonitoringInputs) {
        if let applyOverride {
            applyOverride(inputs)
        } else {
            refreshMonitoring(goals: inputs.goals, sessionTimeoutMinutes: inputs.sessionTimeoutMinutes)
        }
    }
}

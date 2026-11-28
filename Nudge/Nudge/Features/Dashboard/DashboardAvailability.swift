import DeviceActivity

/// Whether the dashboard can show a report, or which state explains why not.
enum DashboardAvailability: Equatable {
    /// The permission store has not read the statuses yet (cold start). Shown as a plain
    /// spinner so the access screen never flashes before the first read.
    case loading
    /// Screen Time access is not granted — reports would be blank.
    case needsAuthorization
    /// Access granted but no `DeviceActivitySchedule` is registered, so the system
    /// has no monitored period to report on (ADR-046).
    case trackingInactive
    case ready

    /// `screenTime` is the shared `PermissionStatusStore` status (system status plus the
    /// monitoring-proved revoke override), so the Dashboard and the banners never disagree
    /// (docs/specs/phase-2-dashboard.md D2). Authorization takes precedence over monitoring:
    /// without it monitoring cannot work anyway.
    static func resolve(screenTime: PermissionStatus, isLoaded: Bool, isMonitoringActive: Bool) -> DashboardAvailability {
        guard isLoaded else { return .loading }
        guard screenTime == .granted else { return .needsAuthorization }
        return isMonitoringActive ? .ready : .trackingInactive
    }

    /// Rebuild the report once when it becomes showable, e.g. right after Screen Time is
    /// granted and monitoring registers (D3).
    static func shouldRefreshOnTransition(from old: DashboardAvailability, to new: DashboardAvailability) -> Bool {
        new == .ready && old != .ready
    }

    /// Resolves with the live monitoring state.
    static func current(screenTime: PermissionStatus, isLoaded: Bool) -> DashboardAvailability {
        resolve(
            screenTime: screenTime,
            isLoaded: isLoaded,
            isMonitoringActive: !DeviceActivityCenter().activities.isEmpty
        )
    }
}

import DeviceActivity
import FamilyControls

/// Whether the dashboard can show a report, or which empty state explains why not.
enum DashboardAvailability: Equatable {
    /// Screen Time access was not granted — reports would be blank.
    case needsAuthorization
    /// Access granted but no `DeviceActivitySchedule` is registered, so the system
    /// has no monitored period to report on (ADR-046).
    case trackingInactive
    case ready

    /// Authorization takes precedence: without it monitoring cannot work anyway.
    static func resolve(isAuthorized: Bool, isMonitoringActive: Bool) -> DashboardAvailability {
        guard isAuthorized else { return .needsAuthorization }
        return isMonitoringActive ? .ready : .trackingInactive
    }

    static func isAuthorized(_ status: AuthorizationStatus) -> Bool {
        if status == .approved { return true }
        if #available(iOS 26.4, *), status == .approvedWithDataAccess { return true }
        return false
    }

    /// Live Screen Time authorization. Also gates the Goals and Categories tabs, whose
    /// pickers and reports need the same access.
    static func isScreenTimeAuthorized() -> Bool {
        isAuthorized(AuthorizationCenter.shared.authorizationStatus)
    }

    /// Reads the live system state.
    static func current() -> DashboardAvailability {
        resolve(
            isAuthorized: isScreenTimeAuthorized(),
            isMonitoringActive: !DeviceActivityCenter().activities.isEmpty
        )
    }
}

import Foundation
import Combine
import FamilyControls
import UserNotifications
import os

// Device permissions (docs/specs/onboarding-progress.md §1, §5). Never stored: read from the
// system, so each device is checked on its own.

enum DevicePermission: String, CaseIterable, Hashable {
    case screenTime
    case notifications
}

enum PermissionStatus: Equatable {
    case notDetermined
    case denied
    case granted

    init(screenTime status: AuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .approved: self = .granted
        // `.approvedWithDataAccess` (iOS 26.4+) and any later approval kind.
        default: self = .granted
        }
    }

    /// `provisional` and `ephemeral` count as on.
    init(notifications status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized, .provisional, .ephemeral: self = .granted
        @unknown default: self = .granted
        }
    }

    /// For logs (no user data).
    var logName: String {
        switch self {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .granted: "granted"
        }
    }
}

/// Logs for permission refreshes, the Screen Time override and banner visibility.
enum PermissionLog {
    static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "Permissions")
}

/// Reads and requests the system permissions. Injectable; tests use a fake.
protocol PermissionStatusProvider: AnyObject {
    func screenTimeStatus() -> PermissionStatus
    func notificationStatus() async -> PermissionStatus
    /// Shows the Screen Time prompt. True when `requestAuthorization` returned without
    /// throwing (the user approved); false when it was declined or failed.
    func requestScreenTimeAuthorization() async -> Bool
    func requestNotificationAuthorization() async
    /// Screen Time changes the system pushes (e.g. revoked in Settings), so the status stays
    /// fresh between foreground refreshes (spec §5c). Emits only real changes.
    var screenTimeStatusChanges: AnyPublisher<PermissionStatus, Never> { get }
}

/// Production provider: FamilyControls `AuthorizationCenter` and `UNUserNotificationCenter`.
@MainActor
final class SystemPermissionStatusProvider: PermissionStatusProvider {

    let screenTimeStatusChanges: AnyPublisher<PermissionStatus, Never>

    /// `authorizationStatus` is injectable for tests; the app observes `AuthorizationCenter`.
    init(authorizationStatus: AnyPublisher<AuthorizationStatus, Never> =
            AuthorizationCenter.shared.$authorizationStatus.eraseToAnyPublisher()) {
        screenTimeStatusChanges = authorizationStatus
            .map(PermissionStatus.init(screenTime:))
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func screenTimeStatus() -> PermissionStatus {
        PermissionStatus(screenTime: AuthorizationCenter.shared.authorizationStatus)
    }

    func notificationStatus() async -> PermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return PermissionStatus(notifications: settings.authorizationStatus)
    }

    func requestScreenTimeAuthorization() async -> Bool {
        // A denial or failure throws; the status read afterwards reflects the outcome.
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            return true
        } catch {
            return false
        }
    }

    func requestNotificationAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        // Just granted (or provisional): get an APNs token now rather than on the next
        // foreground. No-op if the user declined.
        await PushRegistration.registerIfAuthorized()
    }
}

/// What the banners and in-context asks need: the current status and a way to show the system
/// prompt (which refreshes the status). `PermissionStatusStore` in the app; injectable in tests.
@MainActor
protocol PermissionRequesting: AnyObject {
    func status(of permission: DevicePermission) -> PermissionStatus
    func request(_ permission: DevicePermission) async
}

/// The current permission statuses, published for routing and the banners. Refreshed on
/// every return to the foreground (which includes coming back from Settings), after a
/// request, and whenever the system pushes a Screen Time change.
///
/// Screen Time also has a second source: monitoring. FamilyControls caches the authorization
/// status per process, so after a revoke in Settings `AuthorizationCenter` (and its publisher)
/// keeps reporting approved until a relaunch. Two monitoring signals override that cached
/// status with a denial (`ScreenTimeOverride`):
/// - `startMonitoring` throwing `.unauthorized` (cleared by a later successful registration);
/// - monitoring registered earlier today being gone (device finding B: on device a revoke
///   throws nothing and registration succeeds again, so only an approval clears this one).
/// An approved in-app request clears either. In memory only: a relaunch reads a fresh status.
@MainActor
final class PermissionStatusStore: ObservableObject, PermissionRequesting {
    /// Why monitoring overrides the cached system status with a denial.
    enum ScreenTimeOverride: String {
        case monitoringUnauthorized
        case monitoringLapsed
    }

    /// What the banners and routing use: the system status, unless monitoring proved it stale.
    @Published private(set) var screenTime: PermissionStatus = .notDetermined
    @Published private(set) var notifications: PermissionStatus = .notDetermined
    /// False until the first refresh, so nothing routes on a guessed status.
    @Published private(set) var isLoaded = false

    /// Emits after an in-app Screen Time request is approved, so the app re-registers
    /// monitoring right away instead of on the next foreground (device finding C).
    var screenTimeApprovals: AnyPublisher<Void, Never> { approvalSubject.eraseToAnyPublisher() }

    private let provider: PermissionStatusProvider
    private var screenTimeObservation: AnyCancellable?
    private let approvalSubject = PassthroughSubject<Void, Never>()
    /// The last status `AuthorizationCenter` reported (possibly cached; see the type comment).
    private var systemScreenTime: PermissionStatus = .notDetermined
    private var screenTimeOverride: ScreenTimeOverride?

    convenience init() { self.init(provider: SystemPermissionStatusProvider()) }

    init(provider: PermissionStatusProvider) {
        self.provider = provider
        // The system may publish off the main thread; the store is main-actor state.
        screenTimeObservation = provider.screenTimeStatusChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                PermissionLog.logger.log("Screen Time status pushed by the system: \(status.logName, privacy: .public)")
                self.systemScreenTime = status
                self.publishScreenTime()
            }
    }

    func status(of permission: DevicePermission) -> PermissionStatus {
        switch permission {
        case .screenTime: screenTime
        case .notifications: notifications
        }
    }

    func refresh() async {
        PermissionLog.logger.log("permission refresh started")
        systemScreenTime = provider.screenTimeStatus()
        let notifications = await provider.notificationStatus()
        publishScreenTime()
        // Assign only real changes: each @Published write re-renders every observer.
        if self.notifications != notifications { self.notifications = notifications }
        if !isLoaded { isLoaded = true }
        PermissionLog.logger.log("""
            permission refresh finished — screenTime: \(self.screenTime.logName, privacy: .public) \
            (system \(self.systemScreenTime.logName, privacy: .public), \
            override \(self.screenTimeOverride?.rawValue ?? "none", privacy: .public)), \
            notifications: \(notifications.logName, privacy: .public)
            """)
    }

    func request(_ permission: DevicePermission) async {
        switch permission {
        case .screenTime:
            let approved = await provider.requestScreenTimeAuthorization()
            // A request that returned without throwing and reads approved is a real, fresh
            // approval (unlike the cached status), so it ends any monitoring-reported denial.
            let isApproval = approved && provider.screenTimeStatus() == .granted
            PermissionLog.logger.log("Screen Time request finished — approved: \(isApproval, privacy: .public)")
            if isApproval { setOverride(nil, reason: "in-app approval") }
            await refresh()
            if isApproval { approvalSubject.send() }
        case .notifications:
            await provider.requestNotificationAuthorization()
            await refresh()
        }
    }

    /// The monitoring path's Screen Time signals (see the type comment).
    /// - `activitiesLapsedToday`: monitoring registered earlier today was gone before this
    ///   refresh (`MonitoringRegistrationService.activitiesLapsedSinceRegisteringToday`).
    /// - `outcome`: only `DeviceActivityCenter.MonitoringError.unauthorized` marks Screen Time
    ///   denied; a successful registration clears that denial (not a lapse); anything else
    ///   changes nothing.
    func recordMonitoringOutcome(_ outcome: MonitoringRefreshOutcome, activitiesLapsedToday: Bool = false) {
        if activitiesLapsedToday {
            setOverride(.monitoringLapsed, reason: "monitoring registered today is gone")
            return
        }
        switch outcome {
        case .registered where screenTimeOverride == .monitoringUnauthorized:
            setOverride(nil, reason: "monitoring registered")
        case .failed where outcome.isScreenTimeUnauthorized:
            setOverride(.monitoringUnauthorized, reason: "startMonitoring threw unauthorized")
        case .registered, .failed, .notNeeded:
            return
        }
    }

    private func setOverride(_ override: ScreenTimeOverride?, reason: String) {
        guard screenTimeOverride != override else { return }
        screenTimeOverride = override
        if let override {
            PermissionLog.logger.notice("Screen Time override set: \(override.rawValue, privacy: .public) — \(reason, privacy: .public)")
        } else {
            PermissionLog.logger.notice("Screen Time override cleared — \(reason, privacy: .public)")
        }
        publishScreenTime()
    }

    private func publishScreenTime() {
        let effective = screenTimeOverride != nil ? .denied : systemScreenTime
        // Assign only real changes: each @Published write re-renders every observer.
        if screenTime != effective { screenTime = effective }
    }
}

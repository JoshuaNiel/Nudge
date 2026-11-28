import Foundation
import Combine
import FamilyControls
import UserNotifications

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
/// Screen Time also has a second source: monitoring registration. FamilyControls caches the
/// authorization status per process, so after a revoke in Settings `AuthorizationCenter`
/// keeps reporting approved until a relaunch, while `startMonitoring` already throws
/// `.unauthorized`. `recordMonitoringOutcome` turns that into a denial that overrides the
/// cached status until a later registration succeeds or a request is approved.
@MainActor
final class PermissionStatusStore: ObservableObject, PermissionRequesting {
    /// What the banners and routing use: the system status, unless monitoring proved it stale.
    @Published private(set) var screenTime: PermissionStatus = .notDetermined
    @Published private(set) var notifications: PermissionStatus = .notDetermined
    /// False until the first refresh, so nothing routes on a guessed status.
    @Published private(set) var isLoaded = false

    private let provider: PermissionStatusProvider
    private var screenTimeObservation: AnyCancellable?
    /// The last status `AuthorizationCenter` reported (possibly cached; see the type comment).
    private var systemScreenTime: PermissionStatus = .notDetermined
    /// Set when monitoring failed as unauthorized; cleared by a successful registration or an
    /// approved request. In memory only: a relaunch reads a fresh status anyway.
    private var monitoringReportedUnauthorized = false

    convenience init() { self.init(provider: SystemPermissionStatusProvider()) }

    init(provider: PermissionStatusProvider) {
        self.provider = provider
        // The system may publish off the main thread; the store is main-actor state.
        screenTimeObservation = provider.screenTimeStatusChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
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
        systemScreenTime = provider.screenTimeStatus()
        let notifications = await provider.notificationStatus()
        publishScreenTime()
        // Assign only real changes: each @Published write re-renders every observer.
        if self.notifications != notifications { self.notifications = notifications }
        if !isLoaded { isLoaded = true }
    }

    func request(_ permission: DevicePermission) async {
        switch permission {
        case .screenTime:
            let approved = await provider.requestScreenTimeAuthorization()
            // A request that returned without throwing and reads approved is a real, fresh
            // approval (unlike the cached status), so it ends a monitoring-reported denial.
            if approved && provider.screenTimeStatus() == .granted {
                monitoringReportedUnauthorized = false
            }
        case .notifications:
            await provider.requestNotificationAuthorization()
        }
        await refresh()
    }

    /// The monitoring path's Screen Time signal (see the type comment). Only
    /// `DeviceActivityCenter.MonitoringError.unauthorized` marks Screen Time denied; a
    /// successful registration proves access and clears it; anything else changes nothing.
    func recordMonitoringOutcome(_ outcome: MonitoringRefreshOutcome) {
        switch outcome {
        case .registered:
            monitoringReportedUnauthorized = false
        case .failed where outcome.isScreenTimeUnauthorized:
            monitoringReportedUnauthorized = true
        case .failed, .notNeeded:
            return
        }
        publishScreenTime()
    }

    private func publishScreenTime() {
        let effective = monitoringReportedUnauthorized ? .denied : systemScreenTime
        // Assign only real changes: each @Published write re-renders every observer.
        if screenTime != effective { screenTime = effective }
    }
}

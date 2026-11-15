import Foundation
import Combine
import UserNotifications
import os

// MARK: - Permission status

/// The user's notification permission, reduced to what the Settings row shows.
enum NotificationPermissionStatus: Equatable {
    case allowed
    case off
    case notAsked

    /// Provisional (quiet) and ephemeral (App Clip) authorization both deliver, so they
    /// count as allowed. Unknown future cases are treated as off: the safe reading.
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional, .ephemeral: self = .allowed
        case .denied: self = .off
        case .notDetermined: self = .notAsked
        @unknown default: self = .off
        }
    }
}

// MARK: - Permission provider

/// The system notification permission, behind a protocol so the row is tested without
/// `UNUserNotificationCenter`.
protocol NotificationPermissionProviding {
    func currentStatus() async -> NotificationPermissionStatus
    /// Shows the system prompt (only ever shown once per install by iOS).
    func requestAuthorization() async throws -> Bool
}

struct SystemNotificationPermissionProvider: NotificationPermissionProviding {
    func currentStatus() async -> NotificationPermissionStatus {
        NotificationPermissionStatus(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
}

// MARK: - Row state (pure)

enum NotificationRowAction: Equatable {
    case none
    /// Denied: only the Settings app can turn it back on.
    case openSettings
    /// Never asked: the system prompt is still available.
    case requestPermission
}

/// What the Settings → Notifications row shows for a permission status. `nil` = still
/// checking.
struct NotificationRowState: Equatable {
    let statusText: String
    let action: NotificationRowAction
    let actionTitle: String?

    static func make(_ status: NotificationPermissionStatus?) -> NotificationRowState {
        switch status {
        case .allowed:
            return NotificationRowState(statusText: "Allowed", action: .none, actionTitle: nil)
        case .off:
            return NotificationRowState(statusText: "Off", action: .openSettings, actionTitle: "Open Settings")
        case .notAsked:
            return NotificationRowState(statusText: "Not asked", action: .requestPermission, actionTitle: "Turn On")
        case nil:
            return NotificationRowState(statusText: "Checking…", action: .none, actionTitle: nil)
        }
    }
}

// MARK: - ViewModel

@MainActor
final class NotificationSettingsViewModel: ObservableObject {
    @Published private(set) var status: NotificationPermissionStatus? = nil
    @Published private(set) var isRequesting = false

    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "NotificationSettings")

    private let provider: NotificationPermissionProviding

    // Production init (ADR-028 two-init pattern).
    init() { self.provider = SystemNotificationPermissionProvider() }

    // Test init.
    init(provider: NotificationPermissionProviding) { self.provider = provider }

    var rowState: NotificationRowState { NotificationRowState.make(status) }

    func refresh() async {
        status = await provider.currentStatus()
    }

    /// Asks for permission, then re-reads the real status whatever the outcome.
    func turnOn() async {
        isRequesting = true
        defer { isRequesting = false }
        do {
            _ = try await provider.requestAuthorization()
        } catch {
            Self.logger.error("notification permission request failed: \(error.localizedDescription, privacy: .public)")
        }
        await refresh()
    }
}

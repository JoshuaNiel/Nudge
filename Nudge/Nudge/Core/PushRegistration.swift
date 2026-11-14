import UIKit
import UserNotifications

/// Registers with APNs when — and only when — the user has already granted notification
/// permission. It never prompts: onboarding's `PermissionsView` owns the permission request.
enum PushRegistration {

    /// Statuses under which iOS will display remote notifications.
    static func shouldRegister(for status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    /// Calls `registerForRemoteNotifications()` if permission is granted. The token arrives
    /// asynchronously in `AppDelegate`. Cheap and idempotent — safe to call on every foreground.
    static func registerIfAuthorized() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard shouldRegister(for: status) else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }
}

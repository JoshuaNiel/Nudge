import UIKit
import UserNotifications

/// UIKit bridge for notification-center delegation.
///
/// Exists so Nudge's notifications are shown even while Nudge is in the foreground.
/// Without a `UNUserNotificationCenterDelegate`, iOS silently drops the banner for a
/// foregrounded app — and because events count past activity (ADR-054), re-registering
/// on foreground often fires an already-passed limit at exactly that moment.
///
/// `feat/apns-registration` (#14) extends this class with APNs token and push-tap
/// handling; keep `foregroundPresentationOptions` when merging.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// How every Nudge notification is presented while the app is foregrounded.
    static let foregroundPresentationOptions: UNNotificationPresentationOptions = [.banner, .sound, .list]

    // MARK: - UIApplicationDelegate

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Set before launch finishes so the delegate is in place for the first notification.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners while foregrounded — including the local notifications the monitor
    /// extension posts.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.foregroundPresentationOptions
    }
}

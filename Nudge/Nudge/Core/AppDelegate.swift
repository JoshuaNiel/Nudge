import UIKit
import UserNotifications
import os

/// UIKit bridge for APNs registration callbacks and notification-center delegation.
///
/// Kept deliberately thin: token encoding, upload and deep-link parsing live in
/// `DeviceToken`, `PushTokenManager` and `PushPayload`, which are unit-tested.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// How every Nudge notification — reply pushes and the monitor extension's local
    /// notifications — is presented while the app is foregrounded. Without this iOS
    /// drops the banner, and with past activity counted (ADR-054) a passed limit often
    /// fires right as Nudge re-registers on foreground.
    static let foregroundPresentationOptions: UNNotificationPresentationOptions = [.banner, .sound, .list]

    /// Deep-link state for push taps. Injected into the SwiftUI environment by `NudgeApp`.
    let pushRouter = PushRouter()

    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "AppDelegate")

    private var deviceTokenHandler: ((String) -> Void)?
    /// Holds a token that arrived before `NudgeApp` installed its handler.
    private var bufferedDeviceToken: String?

    /// Installs the consumer for APNs tokens and flushes any token that arrived earlier.
    func setDeviceTokenHandler(_ handler: @escaping (String) -> Void) {
        deviceTokenHandler = handler
        if let token = bufferedDeviceToken {
            bufferedDeviceToken = nil
            handler(token)
        }
    }

    // MARK: - UIApplicationDelegate

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Must be set before launch finishes so a cold-start tap is delivered to `didReceive`.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = DeviceToken.hexString(from: deviceToken)
        if let deviceTokenHandler {
            deviceTokenHandler(token)
        } else {
            bufferedDeviceToken = token
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected on builds without the Push Notifications capability (aps-environment).
        Self.logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners while foregrounded — for reply pushes and for the local notifications
    /// the monitor extension posts.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.foregroundPresentationOptions
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Only a tap on the notification itself opens the app to the nudge.
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        // Parse here (nonisolated, pure) so only a Sendable Int crosses to the main actor.
        guard let nudgeId = PushPayload.nudgeId(from: response.notification.request.content.userInfo) else {
            return
        }
        await MainActor.run {
            self.pushRouter.handleNudgeTap(nudgeId: nudgeId)
        }
    }
}

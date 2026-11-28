import Testing
import Foundation
import FamilyControls
import UserNotifications
@testable import Nudge

// Device permission statuses and the post-onboarding permission banners
// (docs/specs/onboarding-progress.md §5).

@MainActor
private final class FakePermissionProvider: PermissionStatusProvider {
    var screenTime: PermissionStatus
    var notifications: PermissionStatus
    /// What a request changes the status to.
    var screenTimeAfterRequest: PermissionStatus?
    var notificationsAfterRequest: PermissionStatus?
    private(set) var screenTimeRequests = 0
    private(set) var notificationRequests = 0

    init(screenTime: PermissionStatus, notifications: PermissionStatus) {
        self.screenTime = screenTime
        self.notifications = notifications
    }

    func screenTimeStatus() -> PermissionStatus { screenTime }
    func notificationStatus() async -> PermissionStatus { notifications }

    func requestScreenTimeAuthorization() async {
        screenTimeRequests += 1
        if let screenTimeAfterRequest { screenTime = screenTimeAfterRequest }
    }

    func requestNotificationAuthorization() async {
        notificationRequests += 1
        if let notificationsAfterRequest { notifications = notificationsAfterRequest }
    }
}

// MARK: - Status mapping

@Suite("Permission status mapping")
@MainActor
struct PermissionStatusMappingTests {

    @Test func screenTime() {
        #expect(PermissionStatus(screenTime: .notDetermined) == .notDetermined)
        #expect(PermissionStatus(screenTime: .denied) == .denied)
        #expect(PermissionStatus(screenTime: .approved) == .granted)
    }

    @Test func notificationsCountProvisionalAndEphemeralAsOn() {
        #expect(PermissionStatus(notifications: .notDetermined) == .notDetermined)
        #expect(PermissionStatus(notifications: .denied) == .denied)
        #expect(PermissionStatus(notifications: .authorized) == .granted)
        #expect(PermissionStatus(notifications: .provisional) == .granted)
        #expect(PermissionStatus(notifications: .ephemeral) == .granted)
    }
}

// MARK: - PermissionStatusStore

@Suite("PermissionStatusStore")
@MainActor
struct PermissionStatusStoreTests {

    @Test func isNotLoadedUntilTheFirstRefresh() async {
        let provider = FakePermissionProvider(screenTime: .denied, notifications: .granted)
        let store = PermissionStatusStore(provider: provider)
        #expect(!store.isLoaded)

        await store.refresh()

        #expect(store.isLoaded)
        #expect(store.screenTime == .denied)
        #expect(store.notifications == .granted)
    }

    @Test func refreshPicksUpAChangeMadeInSettings() async {
        let provider = FakePermissionProvider(screenTime: .denied, notifications: .denied)
        let store = PermissionStatusStore(provider: provider)
        await store.refresh()

        provider.screenTime = .granted
        provider.notifications = .granted
        await store.refresh()

        #expect(store.screenTime == .granted)
        #expect(store.notifications == .granted)
    }

    @Test func requestAsksTheSystemAndRefreshes() async {
        let provider = FakePermissionProvider(screenTime: .notDetermined, notifications: .notDetermined)
        provider.screenTimeAfterRequest = .granted
        provider.notificationsAfterRequest = .denied
        let store = PermissionStatusStore(provider: provider)
        await store.refresh()

        await store.request(.screenTime)
        await store.request(.notifications)

        #expect(provider.screenTimeRequests == 1)
        #expect(provider.notificationRequests == 1)
        #expect(store.screenTime == .granted)
        #expect(store.notifications == .denied)
        #expect(store.status(of: .screenTime) == .granted)
        #expect(store.status(of: .notifications) == .denied)
    }
}

// MARK: - Banners

@Suite("Permission banners")
@MainActor
struct PermissionBannerTests {

    private let statuses: [PermissionStatus] = [.notDetermined, .denied, .granted]

    @Test func screenTimeBannerShowsOnDashboardAndGoalsWhenNotApproved() {
        for status in statuses {
            for screen in [PermissionBannerScreen.dashboard, .goals] {
                let visible = PermissionBanners.visible(on: screen, screenTime: status, notifications: .granted)
                #expect(visible == (status == .granted ? [] : [.screenTime]), "\(screen) \(status)")
            }
            #expect(PermissionBanners.visible(on: .friends, screenTime: status, notifications: .granted).isEmpty)
        }
    }

    @Test func notificationBannerShowsOnDashboardGoalsAndFriendsWhenOff() {
        for status in statuses {
            for screen in [PermissionBannerScreen.dashboard, .goals, .friends] {
                let visible = PermissionBanners.visible(on: screen, screenTime: .granted, notifications: status)
                #expect(visible == (status == .granted ? [] : [.notifications]), "\(screen) \(status)")
            }
        }
    }

    @Test func bothBannersStackScreenTimeFirst() {
        #expect(PermissionBanners.visible(on: .dashboard, screenTime: .denied, notifications: .notDetermined)
                == [.screenTime, .notifications])
        #expect(PermissionBanners.visible(on: .friends, screenTime: .denied, notifications: .notDetermined)
                == [.notifications])
    }

    @Test func actionDependsOnStatus() {
        #expect(PermissionBanners.action(for: .screenTime, status: .notDetermined) == .requestAuthorization)
        #expect(PermissionBanners.action(for: .screenTime, status: .denied) == .openAppSettings)
        #expect(PermissionBanners.action(for: .screenTime, status: .granted) == nil)
        #expect(PermissionBanners.action(for: .notifications, status: .notDetermined) == .requestAuthorization)
        #expect(PermissionBanners.action(for: .notifications, status: .denied) == .openNotificationSettings)
        #expect(PermissionBanners.action(for: .notifications, status: .granted) == nil)
    }

    @Test func copyMatchesTheSpec() {
        #expect(PermissionBanners.message(for: .screenTime)
                == "Screen Time access needed. Nudge can't track your usage or goals.")
        #expect(PermissionBanners.buttonTitle(for: .screenTime) == "Allow")
        #expect(PermissionBanners.message(for: .notifications)
                == "Notifications are off. You won't be alerted when you hit a limit.")
        #expect(PermissionBanners.buttonTitle(for: .notifications) == "Turn On")
    }
}

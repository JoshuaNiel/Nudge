import Testing
import Foundation
import Combine
import FamilyControls
import UserNotifications
import UIKit
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
    /// Pushes a Screen Time change, as `AuthorizationCenter` does (spec §5c).
    let screenTimeSubject = PassthroughSubject<PermissionStatus, Never>()
    var screenTimeStatusChanges: AnyPublisher<PermissionStatus, Never> { screenTimeSubject.eraseToAnyPublisher() }

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

    @Test(.timeLimit(.minutes(1)))
    func aPushedScreenTimeChangeUpdatesTheStoreWithoutARefresh() async {
        let provider = FakePermissionProvider(screenTime: .granted, notifications: .granted)
        let store = PermissionStatusStore(provider: provider)
        await store.refresh()

        // Revoked in Settings: the system publishes it, no foreground refresh happens.
        provider.screenTimeSubject.send(.denied)

        let updated = await store.$screenTime.values.first { $0 == .denied }
        #expect(updated == .denied)
        #expect(store.notifications == .granted)
    }
}

// MARK: - System provider (spec §5c)

@Suite("SystemPermissionStatusProvider")
@MainActor
struct SystemPermissionStatusProviderTests {

    @Test func republishesScreenTimeChangesFromTheInjectedPublisher() {
        let system = PassthroughSubject<AuthorizationStatus, Never>()
        let provider = SystemPermissionStatusProvider(authorizationStatus: system.eraseToAnyPublisher())
        var received: [PermissionStatus] = []
        let cancellable = provider.screenTimeStatusChanges.sink { received.append($0) }

        system.send(.notDetermined)
        system.send(.denied)
        system.send(.denied)
        system.send(.approved)

        #expect(received == [.notDetermined, .denied, .granted])
        cancellable.cancel()
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

    /// §5b: Screen Time always shows the system prompt; notifications prompt only when never
    /// asked, otherwise open the app's notification settings.
    @Test func actionDependsOnStatus() {
        #expect(PermissionBanners.action(for: .screenTime, status: .notDetermined) == .requestAuthorization)
        #expect(PermissionBanners.action(for: .screenTime, status: .denied) == .requestAuthorization)
        #expect(PermissionBanners.action(for: .screenTime, status: .granted) == nil)
        #expect(PermissionBanners.action(for: .notifications, status: .notDetermined) == .requestAuthorization)
        #expect(PermissionBanners.action(for: .notifications, status: .denied) == .openNotificationSettings)
        #expect(PermissionBanners.action(for: .notifications, status: .granted) == nil)
    }

    @Test func buttonTitleDependsOnStatus() {
        #expect(PermissionBanners.buttonTitle(for: .screenTime, status: .notDetermined) == "Allow")
        #expect(PermissionBanners.buttonTitle(for: .screenTime, status: .denied) == "Allow")
        #expect(PermissionBanners.buttonTitle(for: .notifications, status: .notDetermined) == "Turn On")
        #expect(PermissionBanners.buttonTitle(for: .notifications, status: .denied) == "Open Settings")
    }

    @Test func copyMatchesTheSpec() {
        #expect(PermissionBanners.message(for: .screenTime)
                == "Screen Time access needed. Nudge can't track your usage or goals.")
        #expect(PermissionBanners.message(for: .notifications)
                == "Notifications are off. You won't be alerted when you hit a limit.")
    }
}

// MARK: - Shared banner/sheet action (spec §5b)

@MainActor
private final class URLRecorder {
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

@Suite("Permission action runner")
@MainActor
struct PermissionActionRunnerTests {

    private func makeStore(screenTime: PermissionStatus, notifications: PermissionStatus)
        async -> (PermissionStatusStore, FakePermissionProvider) {
        let provider = FakePermissionProvider(screenTime: screenTime, notifications: notifications)
        let store = PermissionStatusStore(provider: provider)
        await store.refresh()
        return (store, provider)
    }

    @Test func screenTimeAlwaysShowsTheSystemPromptAndNeverOpensSettings() async {
        for status in [PermissionStatus.notDetermined, .denied] {
            let (store, provider) = await makeStore(screenTime: status, notifications: .granted)
            provider.screenTimeAfterRequest = .granted
            let urls = URLRecorder()

            let result = await PermissionActionRunner.run(.screenTime, requester: store, openURL: urls.open)

            #expect(provider.screenTimeRequests == 1, "\(status)")
            #expect(urls.opened.isEmpty, "\(status)")
            #expect(result == .granted, "\(status)")
        }
    }

    @Test func undeterminedNotificationsShowTheSystemPrompt() async {
        let (store, provider) = await makeStore(screenTime: .granted, notifications: .notDetermined)
        provider.notificationsAfterRequest = .granted
        let urls = URLRecorder()

        let result = await PermissionActionRunner.run(.notifications, requester: store, openURL: urls.open)

        #expect(provider.notificationRequests == 1)
        #expect(urls.opened.isEmpty)
        #expect(result == .granted)
    }

    @Test func deniedNotificationsOpenTheAppsNotificationSettings() async {
        let (store, provider) = await makeStore(screenTime: .granted, notifications: .denied)
        let urls = URLRecorder()

        let result = await PermissionActionRunner.run(.notifications, requester: store, openURL: urls.open)

        #expect(provider.notificationRequests == 0)
        #expect(urls.opened == [URL(string: UIApplication.openNotificationSettingsURLString)!])
        #expect(result == .denied)
    }

    @Test func grantedDoesNothing() async {
        let (store, provider) = await makeStore(screenTime: .granted, notifications: .granted)
        let urls = URLRecorder()

        _ = await PermissionActionRunner.run(.screenTime, requester: store, openURL: urls.open)
        _ = await PermissionActionRunner.run(.notifications, requester: store, openURL: urls.open)

        #expect(provider.screenTimeRequests == 0)
        #expect(provider.notificationRequests == 0)
        #expect(urls.opened.isEmpty)
    }
}

// MARK: - In-context asks on the Goals tab (spec §5b)

@Suite("Goals permission asks")
@MainActor
struct GoalsPermissionAskTests {

    private func makeFlow(screenTime: PermissionStatus, notifications: PermissionStatus)
        async -> (GoalsSheetFlow, PermissionStatusStore, FakePermissionProvider, URLRecorder) {
        let provider = FakePermissionProvider(screenTime: screenTime, notifications: notifications)
        let store = PermissionStatusStore(provider: provider)
        await store.refresh()
        let urls = URLRecorder()
        let flow = GoalsSheetFlow(requester: store, openURL: urls.open)
        return (flow, store, provider, urls)
    }

    @Test func copyMatchesTheSpec() {
        #expect(PermissionAsk.screenTimeForGoals.permission == .screenTime)
        #expect(PermissionAsk.screenTimeForGoals.message == "Nudge needs Screen Time access to track goals.")
        #expect(PermissionAsk.notificationsForGoalLimit.permission == .notifications)
        #expect(PermissionAsk.notificationsForGoalLimit.message
                == "Turn on notifications so Nudge can alert you when you hit this limit.")
        #expect(PermissionAsk.notNowTitle == "Not now")
    }

    // MARK: Add-goal gate

    @Test func addGoalOpensDirectlyWithScreenTimeApproved() async {
        let (flow, _, _, _) = await makeFlow(screenTime: .granted, notifications: .granted)
        flow.addGoalTapped()
        #expect(flow.sheet == .addGoal)
    }

    @Test func addGoalIsBlockedWithoutScreenTime() async {
        for status in [PermissionStatus.notDetermined, .denied] {
            let (flow, _, provider, _) = await makeFlow(screenTime: status, notifications: .granted)
            flow.addGoalTapped()
            #expect(flow.sheet == .ask(.screenTimeForGoals), "\(status)")
            // Asking never prompts by itself.
            #expect(provider.screenTimeRequests == 0)
        }
    }

    @Test func allowPromptsAndContinuesIntoAddGoalOnApproval() async {
        let (flow, _, provider, urls) = await makeFlow(screenTime: .denied, notifications: .granted)
        provider.screenTimeAfterRequest = .granted
        flow.addGoalTapped()

        await flow.primaryTapped()

        #expect(provider.screenTimeRequests == 1)
        #expect(urls.opened.isEmpty)
        #expect(flow.sheet == .addGoal)
    }

    @Test func allowThatIsNotApprovedClosesWithoutOpeningAddGoal() async {
        let (flow, _, provider, _) = await makeFlow(screenTime: .notDetermined, notifications: .granted)
        provider.screenTimeAfterRequest = .denied
        flow.addGoalTapped()

        await flow.primaryTapped()

        #expect(provider.screenTimeRequests == 1)
        #expect(flow.sheet == nil)
    }

    @Test func notNowCancelsAndIsNotRemembered() async {
        let (flow, _, provider, _) = await makeFlow(screenTime: .notDetermined, notifications: .granted)
        flow.addGoalTapped()

        flow.notNowTapped()
        #expect(flow.sheet == nil)
        #expect(provider.screenTimeRequests == 0)

        flow.addGoalTapped()
        #expect(flow.sheet == .ask(.screenTimeForGoals))
    }

    // MARK: Post-save notification ask

    @Test func savingWithNotificationsOnJustClosesAddGoal() async {
        let (flow, _, _, _) = await makeFlow(screenTime: .granted, notifications: .granted)
        flow.addGoalTapped()
        flow.goalSaved()
        #expect(flow.sheet == nil)
    }

    @Test func savingWithNotificationsOffAsks() async {
        for status in [PermissionStatus.notDetermined, .denied] {
            let (flow, _, _, _) = await makeFlow(screenTime: .granted, notifications: status)
            flow.addGoalTapped()
            flow.goalSaved()
            #expect(flow.sheet == .ask(.notificationsForGoalLimit), "\(status)")
        }
    }

    @Test func primaryTitleFollowsTheStatus() async {
        let (undetermined, _, _, _) = await makeFlow(screenTime: .granted, notifications: .notDetermined)
        #expect(undetermined.primaryTitle(for: .notificationsForGoalLimit) == "Turn On")
        let (denied, _, _, _) = await makeFlow(screenTime: .denied, notifications: .denied)
        #expect(denied.primaryTitle(for: .notificationsForGoalLimit) == "Open Settings")
        #expect(denied.primaryTitle(for: .screenTimeForGoals) == "Allow")
    }

    @Test func turnOnPromptsForUndeterminedNotifications() async {
        let (flow, _, provider, urls) = await makeFlow(screenTime: .granted, notifications: .notDetermined)
        provider.notificationsAfterRequest = .granted
        flow.addGoalTapped()
        flow.goalSaved()

        await flow.primaryTapped()

        #expect(provider.notificationRequests == 1)
        #expect(urls.opened.isEmpty)
        #expect(flow.sheet == nil)
    }

    @Test func openSettingsForDeniedNotifications() async {
        let (flow, _, provider, urls) = await makeFlow(screenTime: .granted, notifications: .denied)
        flow.addGoalTapped()
        flow.goalSaved()

        await flow.primaryTapped()

        #expect(provider.notificationRequests == 0)
        #expect(urls.opened == [URL(string: UIApplication.openNotificationSettingsURLString)!])
        #expect(flow.sheet == nil)
    }

    @Test func notNowOnTheNotificationAskJustCloses() async {
        let (flow, _, provider, urls) = await makeFlow(screenTime: .granted, notifications: .denied)
        flow.addGoalTapped()
        flow.goalSaved()

        flow.notNowTapped()

        #expect(flow.sheet == nil)
        #expect(provider.notificationRequests == 0)
        #expect(urls.opened.isEmpty)

        // Asked again on the next save.
        flow.addGoalTapped()
        flow.goalSaved()
        #expect(flow.sheet == .ask(.notificationsForGoalLimit))
    }

    @Test func cancellingAddGoalNeverAsks() async {
        let (flow, _, _, _) = await makeFlow(screenTime: .granted, notifications: .denied)
        flow.addGoalTapped()
        flow.addGoalCancelled()
        #expect(flow.sheet == nil)
    }

    @Test func primaryWithNoAskShowingDoesNothing() async {
        let (flow, _, provider, _) = await makeFlow(screenTime: .notDetermined, notifications: .notDetermined)
        await flow.primaryTapped()
        #expect(provider.screenTimeRequests == 0)
        #expect(provider.notificationRequests == 0)
        #expect(flow.sheet == nil)
    }
}

import Testing
import Foundation
@testable import Nudge

// Onboarding progress: device copy, seeding, merge rules and routing
// (docs/specs/onboarding-progress.md §3–§4). The server, network, outbox storage, clock and
// defaults suites are injected; nothing touches Supabase or `UserDefaults.standard`.

// MARK: - Fakes

@MainActor
private final class FakeOnboardingServer: OnboardingServerProtocol {
    var status = OnboardingServerStatus(completed: false, nextStep: "profile", firstName: nil, lastName: nil)
    var fetchError: Error?
    var writeErrors: [Error?] = []
    private(set) var fetchCount = 0
    private(set) var nameUpdates: [(UUID, String, String)] = []
    private(set) var completedMarks: [UUID] = []

    func fetchStatus(userId: UUID) async throws -> OnboardingServerStatus {
        fetchCount += 1
        if let fetchError { throw fetchError }
        return status
    }

    func updateProfileName(userId: UUID, firstName: String, lastName: String) async throws {
        nameUpdates.append((userId, firstName, lastName))
        if !writeErrors.isEmpty, let error = writeErrors.removeFirst() { throw error }
        status.firstName = firstName
        status.lastName = lastName
        status.nextStep = nil
    }

    func markOnboardingCompleted(userId: UUID) async throws {
        completedMarks.append(userId)
        if !writeErrors.isEmpty, let error = writeErrors.removeFirst() { throw error }
        status.completed = true
    }
}

private func freshDefaults() -> UserDefaults {
    let name = "OnboardingProgressTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// MARK: - OnboardingProgress model

@Suite("OnboardingProgress model")
@MainActor
struct OnboardingProgressModelTests {

    @Test func profileStepPendingUntilBothNamesAreNonBlank() {
        #expect(OnboardingProgress.nextStep(firstName: nil, lastName: nil) == .profile)
        #expect(OnboardingProgress.nextStep(firstName: "Ada", lastName: nil) == .profile)
        #expect(OnboardingProgress.nextStep(firstName: nil, lastName: "Lovelace") == .profile)
        #expect(OnboardingProgress.nextStep(firstName: "  ", lastName: "Lovelace") == .profile)
        #expect(OnboardingProgress.nextStep(firstName: "Ada", lastName: "\t") == .profile)
        #expect(OnboardingProgress.nextStep(firstName: "Ada", lastName: "Lovelace") == nil)
    }

    @Test func stepRawValueMatchesTheServerFunction() {
        #expect(OnboardingAccountStep.profile.rawValue == "profile")
    }

    @Test func decodesTheOnboardingStatusRPCResponse() throws {
        let pending = try JSONDecoder().decode(OnboardingStatusResponse.self,
                                               from: Data(#"{"completed": false, "next_step": "profile"}"#.utf8))
        #expect(pending.completed == false)
        #expect(pending.nextStep == "profile")

        let done = try JSONDecoder().decode(OnboardingStatusResponse.self,
                                            from: Data(#"{"completed": true, "next_step": null}"#.utf8))
        #expect(done.completed)
        #expect(done.nextStep == nil)
    }

    @Test func outboxPayloadEncodesFirstAndLastName() throws {
        let data = try JSONEncoder().encode(ProfileNamePayload(firstName: "Ada", lastName: "Lovelace"))
        let decoded = try JSONDecoder().decode(ProfileNamePayload.self, from: data)
        #expect(decoded == ProfileNamePayload(firstName: "Ada", lastName: "Lovelace"))
    }

    @Test func outboxKindsAreNamedAndCoalesceAsSpecified() {
        #expect(OnboardingOutboxKinds.updateProfileName.name == "updateProfileName")
        #expect(OnboardingOutboxKinds.updateProfileName.coalescing == .replacePending)
        #expect(OnboardingOutboxKinds.markOnboardingCompleted.name == "markOnboardingCompleted")
        #expect(OnboardingOutboxKinds.markOnboardingCompleted.coalescing == .oncePending)
    }
}

// MARK: - OnboardingStore (device copy, keyed by user)

@Suite("OnboardingStore")
@MainActor
struct OnboardingStoreTests {

    private let defaults = freshDefaults()

    @Test func savesAndLoadsPerUser() {
        let store = OnboardingStore(defaults: defaults)
        let userA = UUID(), userB = UUID()
        let progress = OnboardingProgress(completed: true, nextStep: nil, firstName: "Ada", lastName: "L",
                                          updatedAt: Date(timeIntervalSince1970: 100))
        store.save(progress, for: userA)

        #expect(store.load(for: userA) == progress)
        #expect(store.load(for: userB) == nil)
        // Persisted: a new store over the same defaults reads it.
        #expect(OnboardingStore(defaults: defaults).load(for: userA) == progress)
    }

    @Test func removeDeletesOnlyThatUsersCopy() {
        let store = OnboardingStore(defaults: defaults)
        let userA = UUID(), userB = UUID()
        let progress = OnboardingProgress(completed: false, nextStep: .profile, firstName: nil, lastName: nil,
                                          updatedAt: Date(timeIntervalSince1970: 1))
        store.save(progress, for: userA)
        store.save(progress, for: userB)
        store.remove(for: userA)
        #expect(store.load(for: userA) == nil)
        #expect(store.load(for: userB) == progress)
    }

    @Test func hasAnyCompletedCopyLooksAtEveryUsersCopy() {
        let store = OnboardingStore(defaults: defaults)
        #expect(!store.hasAnyCompletedCopy())

        let pending = OnboardingProgress(completed: false, nextStep: .profile, firstName: nil, lastName: nil,
                                         updatedAt: Date(timeIntervalSince1970: 1))
        store.save(pending, for: UUID())
        #expect(!store.hasAnyCompletedCopy())

        var done = pending
        done.completed = true
        store.save(done, for: UUID())
        #expect(store.hasAnyCompletedCopy())
    }
}

// MARK: - Merge rules (device ← server)

@Suite("Onboarding merge rules")
@MainActor
struct OnboardingMergeTests {

    private let now = Date(timeIntervalSince1970: 5_000)

    private func device(completed: Bool, first: String?, last: String?) -> OnboardingProgress {
        OnboardingProgress(completed: completed,
                           nextStep: OnboardingProgress.nextStep(firstName: first, lastName: last),
                           firstName: first, lastName: last, updatedAt: Date(timeIntervalSince1970: 1))
    }

    private func server(completed: Bool, first: String?, last: String?) -> OnboardingServerStatus {
        OnboardingServerStatus(completed: completed,
                               nextStep: OnboardingProgress.nextStep(firstName: first, lastName: last)?.rawValue,
                               firstName: first, lastName: last)
    }

    @Test func completedIsDeviceOrServer() {
        for d in [true, false] {
            for s in [true, false] {
                let merged = OnboardingMerge.merge(device: device(completed: d, first: "A", last: "B"),
                                                   server: server(completed: s, first: "A", last: "B"),
                                                   hasQueuedNameUpdate: false, now: now)
                #expect(merged.completed == (d || s), "device \(d) server \(s)")
            }
        }
    }

    @Test func queuedNameUpdateKeepsTheDeviceName() {
        let merged = OnboardingMerge.merge(device: device(completed: false, first: "Ada", last: "Lovelace"),
                                           server: server(completed: false, first: nil, last: nil),
                                           hasQueuedNameUpdate: true, now: now)
        #expect(merged.firstName == "Ada")
        #expect(merged.lastName == "Lovelace")
        #expect(merged.nextStep == nil)
    }

    @Test func withoutQueuedUpdateTheServerNameReplacesTheDevice() {
        let merged = OnboardingMerge.merge(device: device(completed: false, first: "Ada", last: "Lovelace"),
                                           server: server(completed: false, first: "Grace", last: "Hopper"),
                                           hasQueuedNameUpdate: false, now: now)
        #expect(merged.firstName == "Grace")
        #expect(merged.lastName == "Hopper")
    }

    @Test func serverBlankNamesSendTheUserBackToProfile() {
        // e.g. the server rejected the name and the write was dropped.
        let merged = OnboardingMerge.merge(device: device(completed: false, first: "Ada", last: "Lovelace"),
                                           server: server(completed: false, first: nil, last: nil),
                                           hasQueuedNameUpdate: false, now: now)
        #expect(merged.nextStep == .profile)
    }

    @Test func nextStepIsRecomputedOnTheDevice() {
        // The server says "profile" but the queued (newer) device name satisfies it.
        let s = OnboardingServerStatus(completed: false, nextStep: "profile", firstName: nil, lastName: nil)
        let merged = OnboardingMerge.merge(device: device(completed: false, first: "Ada", last: "L"),
                                           server: s, hasQueuedNameUpdate: true, now: now)
        #expect(merged.nextStep == nil)
    }

    @Test func noDeviceCopyTakesTheServer() {
        let merged = OnboardingMerge.merge(device: nil, server: server(completed: true, first: "Ada", last: "L"),
                                           hasQueuedNameUpdate: false, now: now)
        #expect(merged == OnboardingProgress(completed: true, nextStep: nil, firstName: "Ada", lastName: "L", updatedAt: now))
    }
}

// MARK: - Routing (spec §4)

@Suite("Onboarding routing")
@MainActor
struct OnboardingRoutingTests {

    private func progress(nextStep: OnboardingAccountStep?, completed: Bool) -> OnboardingProgress {
        OnboardingProgress(completed: completed, nextStep: nextStep, firstName: nil, lastName: nil,
                           updatedAt: Date(timeIntervalSince1970: 0))
    }

    private let statuses: [PermissionStatus] = [.notDetermined, .denied, .granted]

    /// Every combination of (nextStep, completed, Screen Time, notifications, page done).
    @Test func everyCombination() {
        for nextStep in [OnboardingAccountStep.profile, nil] {
            for completed in [true, false] {
                for screenTime in statuses {
                    for notifications in statuses {
                        for pageDone in [false, true] {
                            let result = OnboardingRouting.destination(
                                progress: progress(nextStep: nextStep, completed: completed),
                                screenTime: screenTime, notifications: notifications,
                                permissionsPageDone: pageDone)

                            var pending: [DevicePermission] = []
                            if screenTime == .notDetermined { pending.append(.screenTime) }
                            if notifications == .notDetermined { pending.append(.notifications) }

                            let expected: OnboardingDestination
                            if nextStep == .profile {
                                expected = .profileSetup
                            } else if pageDone {
                                // Shown once per device (§5b): never again, even if unasked.
                                expected = completed ? .app : .permissions(pending: [])
                            } else if !completed || !pending.isEmpty {
                                expected = .permissions(pending: pending)
                            } else {
                                expected = .app
                            }
                            #expect(result == expected,
                                    "nextStep \(String(describing: nextStep)) completed \(completed) st \(screenTime) n \(notifications) page \(pageDone)")
                        }
                    }
                }
            }
        }
    }

    @Test func profileStepWinsEvenForACompletedUser() {
        // e.g. the server rejected the name after completion.
        #expect(OnboardingRouting.destination(progress: progress(nextStep: .profile, completed: true),
                                              screenTime: .granted, notifications: .granted,
                                              permissionsPageDone: false) == .profileSetup)
        #expect(OnboardingRouting.destination(progress: progress(nextStep: .profile, completed: true),
                                              screenTime: .granted, notifications: .granted,
                                              permissionsPageDone: true) == .profileSetup)
    }

    @Test func completedUserOnNewDeviceSeesOnlyUnaskedPermissions() {
        #expect(OnboardingRouting.destination(progress: progress(nextStep: nil, completed: true),
                                              screenTime: .notDetermined, notifications: .granted,
                                              permissionsPageDone: false)
                == .permissions(pending: [.screenTime]))
    }

    @Test func deniedCountsAsAsked() {
        #expect(OnboardingRouting.destination(progress: progress(nextStep: nil, completed: true),
                                              screenTime: .denied, notifications: .denied,
                                              permissionsPageDone: false) == .app)
    }

    @Test func notCompletedWithEverythingAskedStillFinishesThroughPermissions() {
        #expect(OnboardingRouting.destination(progress: progress(nextStep: nil, completed: false),
                                              screenTime: .granted, notifications: .denied,
                                              permissionsPageDone: false)
                == .permissions(pending: []))
    }

    @Test func pageShownOnceIsNeverShownAgainEvenWithUnaskedPermissions() {
        #expect(OnboardingRouting.destination(progress: progress(nextStep: nil, completed: true),
                                              screenTime: .notDetermined, notifications: .notDetermined,
                                              permissionsPageDone: true) == .app)
    }

    @Test func pageAlreadyShownOnThisDeviceStillFinishesANewAccountWithoutAsking() {
        // Another account finished the page on this device; this one just set up a profile.
        #expect(OnboardingRouting.destination(progress: progress(nextStep: nil, completed: false),
                                              screenTime: .notDetermined, notifications: .notDetermined,
                                              permissionsPageDone: true) == .permissions(pending: []))
    }
}

// MARK: - Permissions page shown once per device (spec §5b)

@Suite("Permissions page shown once")
@MainActor
struct PermissionsPageTrackerTests {

    private let defaults = freshDefaults()

    private func makeTracker(completedDeviceCopy: Bool = false) -> PermissionsPageTracker {
        PermissionsPageTracker(defaults: defaults, hasCompletedDeviceCopy: { completedDeviceCopy })
    }

    @Test func newDeviceHasNotShownThePage() {
        let tracker = makeTracker()
        #expect(!tracker.isFinished)
        // The inference ran once; the result is recorded so it never runs again.
        #expect(defaults.object(forKey: AppStorageKeys.permissionsPageShown) as? Bool == false)
    }

    @Test func reachingThePageRecordsTheFlagButKeepsItOnScreen() {
        let tracker = makeTracker()
        tracker.markReached()
        #expect(defaults.bool(forKey: AppStorageKeys.permissionsPageShown))
        #expect(!tracker.isFinished)
    }

    @Test func finishingThePageEndsIt() {
        let tracker = makeTracker()
        tracker.markReached()
        tracker.finish()
        #expect(tracker.isFinished)
        #expect(defaults.bool(forKey: AppStorageKeys.permissionsPageShown))
    }

    @Test func reachedPageIsFinishedOnTheNextLaunch() {
        // e.g. the app was killed while the page was up: whatever happened there finished it.
        makeTracker().markReached()
        #expect(makeTracker().isFinished)
    }

    @Test func finishedPageIsFinishedOnTheNextLaunch() {
        let first = makeTracker()
        first.markReached()
        first.finish()
        #expect(makeTracker().isFinished)
    }

    @Test func existingUserWithTheLegacyFlagHasAlreadySeenThePage() {
        defaults.set(true, forKey: AppStorageKeys.onboardingComplete)
        #expect(makeTracker().isFinished)
        #expect(defaults.bool(forKey: AppStorageKeys.permissionsPageShown))
    }

    @Test func existingUserWithACompletedDeviceCopyHasAlreadySeenThePage() {
        #expect(makeTracker(completedDeviceCopy: true).isFinished)
        #expect(defaults.bool(forKey: AppStorageKeys.permissionsPageShown))
    }

    @Test func legacyFlagFalseIsNotAnExistingUser() {
        defaults.set(false, forKey: AppStorageKeys.onboardingComplete)
        #expect(!makeTracker().isFinished)
    }

    @Test func inferenceRunsOnlyWhenTheFlagIsMissing() {
        // First launch of a fresh install: nothing to infer, so the page will be shown.
        #expect(!makeTracker().isFinished)
        // Later in that install the server seeds a completed copy (a reinstall); that must not
        // count as "already shown".
        #expect(!makeTracker(completedDeviceCopy: true).isFinished)
    }

    @Test func inferenceRule() {
        #expect(PermissionsPageTracker.inferShown(legacyOnboardingComplete: false, completedDeviceCopy: false) == false)
        #expect(PermissionsPageTracker.inferShown(legacyOnboardingComplete: true, completedDeviceCopy: false))
        #expect(PermissionsPageTracker.inferShown(legacyOnboardingComplete: false, completedDeviceCopy: true))
        #expect(PermissionsPageTracker.inferShown(legacyOnboardingComplete: true, completedDeviceCopy: true))
    }

    @Test func keyName() {
        #expect(AppStorageKeys.permissionsPageShown == "permissionsPageShown")
    }
}

// MARK: - Permissions page: current page (spec §5b)

@Suite("Permissions page order")
@MainActor
struct PermissionsPageOrderTests {

    @Test func showsTheFirstPermissionNotAnsweredOrSkippedOnThisPage() {
        #expect(PermissionsView.currentPage(pending: [.screenTime, .notifications], dismissed: []) == .screenTime)
        #expect(PermissionsView.currentPage(pending: [.screenTime, .notifications], dismissed: [.screenTime])
                == .notifications)
        #expect(PermissionsView.currentPage(pending: [.screenTime, .notifications],
                                            dismissed: [.screenTime, .notifications]) == nil)
        #expect(PermissionsView.currentPage(pending: [], dismissed: []) == nil)
    }
}

// MARK: - OnboardingProgressController (seeding, saving, refresh)

@Suite("OnboardingProgressController")
@MainActor
struct OnboardingProgressControllerTests {

    private let user = UUID()
    private let otherUser = UUID()
    private let defaults = freshDefaults()
    private let legacyDefaults = freshDefaults()
    private let storage = InMemoryOutboxStorage()
    private let clock = TestClock()
    private let server = FakeOnboardingServer()
    private let network: FakeNetwork

    init() {
        network = FakeNetwork(isOnline: true)
    }

    private func makeController(currentUser: UUID? = nil) -> (OnboardingProgressController, Outbox, OnboardingStore) {
        let signedIn = currentUser ?? user
        let outbox = Outbox(storage: storage, network: network, currentUserId: { signedIn }, now: clock.provider)
        let store = OnboardingStore(defaults: defaults)
        let controller = OnboardingProgressController(
            store: store, outbox: outbox, server: server, network: network,
            legacyDefaults: legacyDefaults, now: clock.provider, seedTimeout: .seconds(5)
        )
        return (controller, outbox, store)
    }

    // MARK: Seeding

    @Test func legacyFlagSeedsCompletedQueuesTheMarkAndDeletesTheKey() async {
        legacyDefaults.set(true, forKey: AppStorageKeys.onboardingComplete)
        network.isOnline = false
        let (controller, outbox, store) = makeController()

        await controller.prepare(userId: user)

        #expect(controller.progress?.completed == true)
        #expect(controller.progress?.nextStep == nil)
        #expect(store.load(for: user)?.completed == true)
        #expect(outbox.hasPending(OnboardingOutboxKinds.markOnboardingCompleted, for: user))
        #expect(legacyDefaults.object(forKey: AppStorageKeys.onboardingComplete) == nil)
        #expect(server.fetchCount == 0)
    }

    @Test func legacyFlagSyncsToTheServerWhenOnline() async {
        legacyDefaults.set(true, forKey: AppStorageKeys.onboardingComplete)
        server.status = OnboardingServerStatus(completed: false, nextStep: nil, firstName: "Ada", lastName: "L")
        let (controller, outbox, _) = makeController()

        await controller.prepare(userId: user)
        await outbox.currentFlush?.value

        #expect(server.completedMarks == [user])
        #expect(controller.progress?.completed == true)
        #expect(controller.progress?.nextStep == nil)
    }

    @Test func onlineWithNoCopySeedsFromTheServer() async {
        server.status = OnboardingServerStatus(completed: true, nextStep: nil, firstName: "Ada", lastName: "Lovelace")
        let (controller, _, store) = makeController()

        await controller.prepare(userId: user)

        #expect(server.fetchCount >= 1)
        let expected = OnboardingProgress(completed: true, nextStep: nil, firstName: "Ada", lastName: "Lovelace",
                                          updatedAt: clock.now)
        #expect(controller.progress == expected)
        #expect(store.load(for: user) == expected)
    }

    @Test func offlineWithNoCopyStartsAtProfileSetup() async {
        network.isOnline = false
        let (controller, _, store) = makeController()

        await controller.prepare(userId: user)

        #expect(server.fetchCount == 0)
        #expect(controller.progress?.nextStep == .profile)
        #expect(controller.progress?.completed == false)
        #expect(store.load(for: user)?.nextStep == .profile)
    }

    @Test func failedFetchWithNoCopyFallsBackToProfileSetup() async {
        server.fetchError = URLError(.timedOut)
        let (controller, _, _) = makeController()
        await controller.prepare(userId: user)
        #expect(controller.progress?.nextStep == .profile)
        #expect(controller.progress?.completed == false)
    }

    @Test func existingCopyIsUsedFirstAndThenRefreshed() async {
        let (controller, _, store) = makeController()
        store.save(OnboardingProgress(completed: true, nextStep: nil, firstName: "Ada", lastName: "L",
                                      updatedAt: Date(timeIntervalSince1970: 1)), for: user)
        network.isOnline = false

        await controller.prepare(userId: user)

        #expect(controller.progress?.completed == true)
        #expect(server.fetchCount == 0)
    }

    @Test func copiesAreIsolatedPerUser() async {
        let (controller, _, store) = makeController()
        store.save(OnboardingProgress(completed: true, nextStep: nil, firstName: "A", lastName: "B",
                                      updatedAt: Date(timeIntervalSince1970: 1)), for: otherUser)
        network.isOnline = false

        await controller.prepare(userId: user)

        #expect(controller.progress?.completed == false)
        #expect(controller.progress?.nextStep == .profile)
    }

    @Test func signOutClearsTheInMemoryStateButKeepsTheCopy() async {
        network.isOnline = false
        let (controller, _, store) = makeController()
        await controller.prepare(userId: user)

        await controller.prepare(userId: nil)

        #expect(controller.progress == nil)
        #expect(store.load(for: user) != nil)
    }

    // MARK: Profile + completion

    @Test func saveProfileNameAppliesImmediatelyAndQueuesTheWrite() async {
        network.isOnline = false
        let (controller, outbox, store) = makeController()
        await controller.prepare(userId: user)

        controller.saveProfileName(firstName: "  Ada ", lastName: "Lovelace ")

        #expect(controller.progress?.firstName == "Ada")
        #expect(controller.progress?.lastName == "Lovelace")
        #expect(controller.progress?.nextStep == nil)
        #expect(store.load(for: user)?.firstName == "Ada")
        #expect(outbox.hasPending(OnboardingOutboxKinds.updateProfileName, for: user))
    }

    @Test func offlineProfileNameReachesTheServerAfterReconnecting() async {
        network.isOnline = false
        let (controller, outbox, _) = makeController()
        await controller.prepare(userId: user)
        controller.saveProfileName(firstName: "Ada", lastName: "Lovelace")
        controller.markCompleted()
        #expect(server.nameUpdates.isEmpty)

        network.becomeReachable()
        await outbox.currentFlush?.value

        #expect(server.nameUpdates.map(\.1) == ["Ada"])
        #expect(server.completedMarks == [user])
        #expect(outbox.pendingWrites(for: user).isEmpty)
    }

    @Test func markCompletedSetsTheCopyAndQueuesOnce() async {
        network.isOnline = false
        let (controller, outbox, store) = makeController()
        await controller.prepare(userId: user)
        controller.saveProfileName(firstName: "Ada", lastName: "L")

        controller.markCompleted()
        controller.markCompleted()

        #expect(controller.progress?.completed == true)
        #expect(store.load(for: user)?.completed == true)
        #expect(outbox.pendingWrites(for: user).filter { $0.kind == OnboardingOutboxKinds.markOnboardingCompleted.name }.count == 1)
    }

    @Test func markCompletedIsIgnoredWhileAnAccountStepIsPending() async {
        network.isOnline = false
        let (controller, outbox, _) = makeController()
        await controller.prepare(userId: user)
        controller.markCompleted()
        #expect(controller.progress?.completed == false)
        #expect(!outbox.hasPending(OnboardingOutboxKinds.markOnboardingCompleted, for: user))
    }

    // MARK: Refresh + merge

    @Test func refreshEnqueuesTheMarkWhenTheDeviceIsAheadOfTheServer() async {
        let (controller, outbox, store) = makeController()
        store.save(OnboardingProgress(completed: true, nextStep: nil, firstName: "Ada", lastName: "L",
                                      updatedAt: Date(timeIntervalSince1970: 1)), for: user)
        server.status = OnboardingServerStatus(completed: false, nextStep: nil, firstName: "Ada", lastName: "L")

        await controller.prepare(userId: user)
        await outbox.currentFlush?.value

        #expect(server.completedMarks == [user])
        #expect(controller.progress?.completed == true)
    }

    @Test func rejectedNameIsDroppedAndTheUserIsRoutedBackToProfile() async {
        network.isOnline = false
        let (controller, outbox, _) = makeController()
        await controller.prepare(userId: user)
        controller.saveProfileName(firstName: "Ada", lastName: "Lovelace")
        #expect(controller.progress?.nextStep == nil)

        // The server rejects the name with a permanent constraint error.
        server.writeErrors = [OutboxWriteError.permanent]
        network.isOnline = true
        await controller.refresh()

        #expect(outbox.pendingWrites(for: user).isEmpty)
        #expect(controller.progress?.firstName == nil)
        #expect(controller.progress?.nextStep == .profile)
    }

    @Test func refreshKeepsAQueuedNameWhenTheFlushFails() async {
        network.isOnline = false
        let (controller, outbox, _) = makeController()
        await controller.prepare(userId: user)
        controller.saveProfileName(firstName: "Ada", lastName: "Lovelace")

        server.writeErrors = [URLError(.timedOut)]
        network.isOnline = true
        await controller.refresh()

        #expect(outbox.hasPending(OnboardingOutboxKinds.updateProfileName, for: user))
        #expect(controller.progress?.firstName == "Ada")
        #expect(controller.progress?.nextStep == nil)
    }

    @Test func refreshIsSkippedOffline() async {
        let (controller, _, store) = makeController()
        store.save(OnboardingProgress(completed: false, nextStep: .profile, firstName: nil, lastName: nil,
                                      updatedAt: Date(timeIntervalSince1970: 1)), for: user)
        network.isOnline = false
        await controller.prepare(userId: user)
        await controller.refresh()
        #expect(server.fetchCount == 0)
    }

    // MARK: Account deletion

    @Test func clearingLocalDataRemovesTheCopyAndTheOutboxForThatUserOnly() async {
        network.isOnline = false
        let (_, outbox, store) = makeController()
        let progress = OnboardingProgress(completed: true, nextStep: nil, firstName: "A", lastName: "B",
                                          updatedAt: Date(timeIntervalSince1970: 1))
        store.save(progress, for: user)
        store.save(progress, for: otherUser)
        outbox.enqueue(OnboardingOutboxKinds.markOnboardingCompleted, payload: EmptyPayload(), for: user)
        outbox.enqueue(OnboardingOutboxKinds.markOnboardingCompleted, payload: EmptyPayload(), for: otherUser)

        let clearer = OnboardingLocalDataClearer(store: store, outbox: outbox)
        clearer.clearLocalData(for: user)

        #expect(store.load(for: user) == nil)
        #expect(outbox.pendingWrites(for: user).isEmpty)
        #expect(store.load(for: otherUser) == progress)
        #expect(outbox.pendingWrites(for: otherUser).count == 1)
    }
}

// MARK: - Displayed first name (device finding D)

/// Profile setup saves the name to the device copy (works offline); the server profile is the
/// source of truth once it has a name.
@Suite("AppState displayed first name")
@MainActor
struct DisplayedFirstNameTests {

    @Test func theDeviceNameShowsBeforeTheServerAnswers() {
        #expect(AppState.resolveFirstName(server: nil, device: "Ada") == "Ada")
    }

    /// Online, but the queued name write hasn't reached the server yet.
    @Test func theDeviceNameShowsWhileTheServerHasNone() {
        #expect(AppState.resolveFirstName(server: "", device: "Ada") == "Ada")
    }

    @Test func theServerNameWinsWhenItHasOne() {
        #expect(AppState.resolveFirstName(server: "Grace", device: "Ada") == "Grace")
        #expect(AppState.resolveFirstName(server: "Grace", device: nil) == "Grace")
    }

    @Test func blankDeviceNamesAreIgnored() {
        #expect(AppState.resolveFirstName(server: nil, device: "  ") == "")
        #expect(AppState.resolveFirstName(server: nil, device: nil) == "")
    }

    @Test func savingOfflineUpdatesTheDisplayedNameImmediately() {
        let appState = AppState(observesAuth: false, appGroup: nil)

        appState.setDeviceFirstName(" Ada ")

        #expect(appState.userFirstName == "Ada")
    }
}

import Testing
import Foundation
import Supabase
@testable import Nudge

// In-app account deletion (docs/specs/account-deletion.md).
// Covers the ViewModel state machine and the post-deletion local cleanup. The network call
// (AccountService) and the real DeviceActivityCenter / Supabase session are behind protocols,
// so nothing here touches a server or the device's monitoring registration.

// MARK: - AccountDeletionViewModel state machine

@Suite("AccountDeletionViewModel")
@MainActor
struct AccountDeletionViewModelTests {

    private let log = CallLog()

    private func makeViewModel(
        service: AccountServiceProtocol? = nil
    ) -> (AccountDeletionViewModel, MockAccountService, MockAccountCleanup) {
        let mockService = MockAccountService(log: log)
        let cleanup = MockAccountCleanup(log: log)
        let vm = AccountDeletionViewModel(accountService: service ?? mockService, cleanup: cleanup)
        return (vm, mockService, cleanup)
    }

    @Test func startsIdle() {
        let (vm, _, _) = makeViewModel()
        #expect(vm.state == .idle)
        #expect(vm.isConfirming == false)
        #expect(vm.isDeleting == false)
        #expect(vm.errorMessage == nil)
    }

    @Test func requestDeletionAsksForConfirmation() {
        let (vm, service, _) = makeViewModel()
        vm.requestDeletion()
        #expect(vm.state == .confirming)
        #expect(vm.isConfirming)
        #expect(service.callCount == 0)   // nothing happens until the user confirms
    }

    @Test func cancelReturnsToIdleWithoutCallingServer() {
        let (vm, service, cleanup) = makeViewModel()
        vm.requestDeletion()
        vm.cancelDeletion()
        #expect(vm.state == .idle)
        #expect(service.callCount == 0)
        #expect(cleanup.callCount == 0)
    }

    @Test func confirmWithoutRequestIsIgnored() async {
        let (vm, service, _) = makeViewModel()
        vm.confirmDeletion()
        await vm.deletionTask?.value
        #expect(vm.state == .idle)
        #expect(service.callCount == 0)
    }

    @Test func confirmEntersDeletingSynchronously() async {
        let (vm, _, _) = makeViewModel()
        vm.requestDeletion()
        vm.confirmDeletion()
        // The alert is dismissed in the same runloop turn, so the button must already be
        // disabled + spinning before the network call starts.
        #expect(vm.state == .deleting)
        #expect(vm.isDeleting)
        await vm.deletionTask?.value
    }

    @Test func successDeletesOnServerThenCleansUpLocallyThenFinishes() async {
        let (vm, service, cleanup) = makeViewModel()
        vm.requestDeletion()
        vm.confirmDeletion()
        await vm.deletionTask?.value

        #expect(vm.state == .done)
        #expect(service.callCount == 1)
        #expect(cleanup.callCount == 1)
        #expect(log.entries == ["server.delete", "local.cleanup"])
    }

    @Test func failureSetsErrorAndNeverCleansUpLocally() async {
        let (vm, service, cleanup) = makeViewModel()
        service.errorToThrow = AccountServiceError.serverRejected(status: 500)

        vm.requestDeletion()
        vm.confirmDeletion()
        await vm.deletionTask?.value

        guard case .failed(let message) = vm.state else {
            Issue.record("expected .failed, got \(vm.state)")
            return
        }
        #expect(!message.isEmpty)
        #expect(vm.errorMessage == message)
        #expect(vm.isDeleting == false)
        #expect(cleanup.callCount == 0)
        #expect(log.entries == ["server.delete"])
    }

    @Test func failureMessageDoesNotLeakTransportDetails() async {
        struct LeakyError: LocalizedError {
            var errorDescription: String? { "HTTP 500 service_role key=abc" }
        }
        let (vm, service, _) = makeViewModel()
        service.errorToThrow = LeakyError()

        vm.requestDeletion()
        vm.confirmDeletion()
        await vm.deletionTask?.value

        #expect(vm.errorMessage == AccountDeletionViewModel.failureMessage)
    }

    @Test func doubleTapWhileDeletingCallsServerOnce() async {
        let log = CallLog()
        let gated = GatedAccountService(log: log)
        let cleanup = MockAccountCleanup(log: log)
        let vm = AccountDeletionViewModel(accountService: gated, cleanup: cleanup)

        vm.requestDeletion()
        vm.confirmDeletion()
        let firstTask = vm.deletionTask

        // Wait until the request is genuinely in flight.
        while !gated.isWaiting { await Task.yield() }

        vm.confirmDeletion()      // second tap — ignored
        vm.requestDeletion()      // and re-requesting mid-flight is ignored too
        #expect(vm.state == .deleting)

        gated.release()
        await firstTask?.value

        #expect(gated.callCount == 1)
        #expect(cleanup.callCount == 1)
        #expect(vm.state == .done)
    }

    @Test func dismissingErrorReturnsToIdleAndAllowsRetry() async {
        let (vm, service, cleanup) = makeViewModel()
        service.errorToThrow = AccountServiceError.serverRejected(status: 500)
        vm.requestDeletion()
        vm.confirmDeletion()
        await vm.deletionTask?.value

        vm.dismissError()
        #expect(vm.state == .idle)

        service.errorToThrow = nil
        vm.requestDeletion()
        #expect(vm.state == .confirming)
        vm.confirmDeletion()
        await vm.deletionTask?.value
        #expect(vm.state == .done)
        #expect(service.callCount == 2)
        #expect(cleanup.callCount == 1)
    }

    @Test func requestAfterDoneIsIgnored() async {
        let (vm, _, _) = makeViewModel()
        vm.requestDeletion()
        vm.confirmDeletion()
        await vm.deletionTask?.value

        vm.requestDeletion()
        #expect(vm.state == .done)
    }

    @Test func confirmationCopyCoversSpecPoints() {
        let copy = AccountDeletionViewModel.confirmationMessage.lowercased()
        #expect(copy.contains("friends"))
        #expect(copy.contains("goals"))
        #expect(copy.contains("history"))
        #expect(copy.contains("permanently"))
        #expect(copy.contains("texts"))
        #expect(copy.contains("cannot be undone"))
    }
}

// MARK: - AccountCleanupService (post-deletion local cleanup)

@Suite("AccountCleanupService")
@MainActor
struct AccountCleanupServiceTests {

    private let appGroupSuite: String
    private let appGroup: UserDefaults
    private let appStorageSuite: String
    private let appStorage: UserDefaults
    private let log = CallLog()

    init() {
        appGroupSuite = "AccountCleanupTests.group.\(UUID().uuidString)"
        appGroup = UserDefaults(suiteName: appGroupSuite)!
        appGroup.removePersistentDomain(forName: appGroupSuite)

        appStorageSuite = "AccountCleanupTests.standard.\(UUID().uuidString)"
        appStorage = UserDefaults(suiteName: appStorageSuite)!
        appStorage.removePersistentDomain(forName: appStorageSuite)
    }

    private func makeService() -> (AccountCleanupService, MockMonitoringStopper, MockLocalSession) {
        let monitoring = MockMonitoringStopper(log: log)
        let session = MockLocalSession(log: log, appGroup: appGroup, suite: appGroupSuite)
        let service = AccountCleanupService(
            monitoring: monitoring,
            appGroupSuiteName: appGroupSuite,
            appGroupDefaults: appGroup,
            appStorage: appStorage,
            session: session
        )
        return (service, monitoring, session)
    }

    private func seedAppGroup() {
        appGroup.set("https://example.supabase.co", forKey: AppGroupKeys.supabaseUrl)
        appGroup.set("anon", forKey: AppGroupKeys.anonKey)
        appGroup.set("jwt", forKey: AppGroupKeys.jwt)
        appGroup.set("Ada", forKey: AppGroupKeys.userFirstName)
        appGroup.set(Data([1, 2, 3]), forKey: AppGroupKeys.goalsActive)
        appGroup.set(Data([4, 5]), forKey: AppGroupKeys.friendsAccepted)
        appGroup.set(Data([6]), forKey: AppGroupKeys.triggersPending)
        appGroup.set("2026-11-14", forKey: AppGroupKeys.lastRegisteredDay)
        appGroup.set("total=3600", forKey: AppGroupKeys.lastRegisteredSignature)
        appGroup.set(true, forKey: AppGroupKeys.midnightSyncNeeded)
        appGroup.set(Data([7]), forKey: AppGroupKeys.appSelectionKey("com.example.app"))
        appGroup.set(Data([8]), forKey: AppGroupKeys.categorySelectionKey(42))
        appGroup.set("future", forKey: "nudge.someFutureKey")   // not listed in AppGroupKeys
    }

    @Test func stopsDeviceActivityMonitoring() async {
        let (service, monitoring, _) = makeService()
        await service.performPostDeletionCleanup()
        #expect(monitoring.stopCount == 1)
    }

    @Test func wipesEveryAppGroupKeyIncludingUnlistedOnes() async {
        seedAppGroup()
        #expect(!(appGroup.persistentDomain(forName: appGroupSuite) ?? [:]).isEmpty)

        let (service, _, _) = makeService()
        await service.performPostDeletionCleanup()

        #expect((appGroup.persistentDomain(forName: appGroupSuite) ?? [:]).isEmpty)
        #expect(appGroup.object(forKey: AppGroupKeys.jwt) == nil)
        #expect(appGroup.object(forKey: AppGroupKeys.anonKey) == nil)
        #expect(appGroup.object(forKey: AppGroupKeys.supabaseUrl) == nil)
        #expect(appGroup.object(forKey: AppGroupKeys.goalsActive) == nil)
        #expect(appGroup.object(forKey: AppGroupKeys.triggersPending) == nil)
        #expect(appGroup.object(forKey: AppGroupKeys.lastRegisteredDay) == nil)
        #expect(appGroup.object(forKey: AppGroupKeys.appSelectionKey("com.example.app")) == nil)
        #expect(appGroup.object(forKey: AppGroupKeys.categorySelectionKey(42)) == nil)
        #expect(appGroup.object(forKey: "nudge.someFutureKey") == nil)
    }

    @Test func resetsOnboardingFlagSoANewAccountSeesOnboarding() async {
        appStorage.set(true, forKey: AppStorageKeys.onboardingComplete)
        let (service, _, _) = makeService()
        await service.performPostDeletionCleanup()
        #expect(appStorage.object(forKey: AppStorageKeys.onboardingComplete) == nil)
        #expect(appStorage.bool(forKey: AppStorageKeys.onboardingComplete) == false)
    }

    @Test func keepsDeviceScopedAPNsTokenForTheNextUser() async {
        // The APNs token belongs to the device, not the deleted user; the next account to sign
        // in needs it to upload. Its server row already cascaded away with the user.
        appStorage.set("aa11", forKey: PushTokenManager.tokenDefaultsKey)
        let (service, _, _) = makeService()
        await service.performPostDeletionCleanup()
        #expect(appStorage.string(forKey: PushTokenManager.tokenDefaultsKey) == "aa11")
    }

    @Test func endsLocalSessionLastAfterLocalStateIsWiped() async {
        seedAppGroup()
        let (service, _, session) = makeService()
        await service.performPostDeletionCleanup()

        #expect(session.endCount == 1)
        #expect(log.entries == ["monitoring.stop", "session.endLocal"])
        // The App Group was already empty by the time the session ended (order matters: the
        // sign-out flips AppState, and the extension must not find a stale JWT afterwards).
        #expect(session.appGroupAtSignOut?.isEmpty == true)
    }

    @Test func isSafeOnAnAlreadyEmptySuite() async {
        let (service, monitoring, session) = makeService()
        await service.performPostDeletionCleanup()
        await service.performPostDeletionCleanup()
        #expect(monitoring.stopCount == 2)
        #expect(session.endCount == 2)
        #expect((appGroup.persistentDomain(forName: appGroupSuite) ?? [:]).isEmpty)
    }
}

// MARK: - AccountServiceError mapping

@Suite("AccountServiceError")
@MainActor
struct AccountServiceErrorTests {

    @Test func mapsFunctionHTTPErrorToServerRejected() {
        let mapped = AccountServiceError.map(FunctionsError.httpError(code: 500, data: Data()))
        #expect(mapped as? AccountServiceError == .serverRejected(status: 500))
    }

    @Test func mapsUnauthorizedToServerRejected401() {
        let mapped = AccountServiceError.map(FunctionsError.httpError(code: 401, data: Data()))
        #expect(mapped as? AccountServiceError == .serverRejected(status: 401))
    }

    @Test func passesThroughOtherErrors() {
        let mapped = AccountServiceError.map(URLError(.notConnectedToInternet))
        #expect(mapped is URLError)
    }

    @Test func everyCaseHasADescription() {
        #expect(AccountServiceError.notAuthenticated.errorDescription != nil)
        #expect(AccountServiceError.serverRejected(status: 500).errorDescription != nil)
    }
}

// MARK: - Mocks

@MainActor
private final class CallLog {
    var entries: [String] = []
}

@MainActor
private final class MockAccountService: AccountServiceProtocol {
    let log: CallLog
    var callCount = 0
    var errorToThrow: Error?

    init(log: CallLog) { self.log = log }

    func deleteAccount() async throws {
        callCount += 1
        log.entries.append("server.delete")
        if let errorToThrow { throw errorToThrow }
    }
}

/// Suspends inside `deleteAccount()` until `release()` so a test can act mid-flight.
@MainActor
private final class GatedAccountService: AccountServiceProtocol {
    let log: CallLog
    var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    init(log: CallLog) { self.log = log }

    func deleteAccount() async throws {
        callCount += 1
        log.entries.append("server.delete")
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class MockAccountCleanup: AccountCleanupProtocol {
    let log: CallLog
    var callCount = 0

    init(log: CallLog) { self.log = log }

    func performPostDeletionCleanup() async {
        callCount += 1
        log.entries.append("local.cleanup")
    }
}

@MainActor
private final class MockMonitoringStopper: MonitoringStopping {
    let log: CallLog
    var stopCount = 0

    init(log: CallLog) { self.log = log }

    func stopAllMonitoring() {
        stopCount += 1
        log.entries.append("monitoring.stop")
    }
}

@MainActor
private final class MockLocalSession: LocalSessionEnding {
    let log: CallLog
    private let appGroup: UserDefaults
    private let suite: String
    var endCount = 0
    /// The App Group's contents at the moment the session was ended.
    private(set) var appGroupAtSignOut: [String: Any]?

    init(log: CallLog, appGroup: UserDefaults, suite: String) {
        self.log = log
        self.appGroup = appGroup
        self.suite = suite
    }

    func endLocalSession() async {
        endCount += 1
        log.entries.append("session.endLocal")
        appGroupAtSignOut = appGroup.persistentDomain(forName: suite) ?? [:]
    }
}

import Testing
import Foundation
import SwiftUI
import Supabase
@testable import Nudge

// In-app account deletion (docs/specs/account-deletion.md, sections B, C and D).
// Covers the ViewModel state machine + sheet messages, the AccountService re-auth → delete
// sequence and its error mapping, and the post-deletion local cleanup. The network calls
// (password sign-in, the delete-account function) and the real DeviceActivityCenter /
// Supabase session are behind protocols, so nothing here touches a server or the device's
// monitoring registration.

// MARK: - AccountDeletionViewModel state machine

@Suite("AccountDeletionViewModel")
@MainActor
struct AccountDeletionViewModelTests {

    private let log: CallLog
    private let presenter: MockAccountDeletedPresenter

    init() {
        let log = CallLog()
        self.log = log
        self.presenter = MockAccountDeletedPresenter(log: log)
    }

    private func makeViewModel(
        service: AccountServiceProtocol? = nil
    ) -> (AccountDeletionViewModel, MockAccountService, MockAccountCleanup) {
        let mockService = MockAccountService(log: log)
        let cleanup = MockAccountCleanup(log: log)
        let vm = AccountDeletionViewModel(accountService: service ?? mockService, cleanup: cleanup)
        return (vm, mockService, cleanup)
    }

    /// Opens the sheet, types `password`, taps Delete Account, and waits for the request.
    private func submit(_ vm: AccountDeletionViewModel, password: String = "hunter2") async {
        if vm.state == .idle { vm.requestDeletion() }
        vm.password = password
        vm.confirmDeletion(notifying: presenter)
        await vm.deletionTask?.value
    }

    @Test func startsIdle() {
        let (vm, _, _) = makeViewModel()
        #expect(vm.state == .idle)
        #expect(vm.isConfirming == false)
        #expect(vm.isDeleting == false)
        #expect(vm.isSheetPresented == false)
        #expect(vm.errorMessage == nil)
        #expect(vm.password.isEmpty)
    }

    @Test func requestDeletionOpensTheSheet() {
        let (vm, service, _) = makeViewModel()
        vm.requestDeletion()
        #expect(vm.state == .confirming)
        #expect(vm.isConfirming)
        #expect(vm.isSheetPresented)
        #expect(service.callCount == 0)   // nothing happens until the user confirms
    }

    @Test func cancelReturnsToIdleWithoutCallingServer() {
        let (vm, service, cleanup) = makeViewModel()
        vm.requestDeletion()
        vm.password = "typed"
        vm.cancelDeletion()
        #expect(vm.state == .idle)
        #expect(vm.isSheetPresented == false)
        #expect(vm.password.isEmpty)      // not kept around after the sheet closes
        #expect(service.callCount == 0)
        #expect(cleanup.callCount == 0)
    }

    @Test func confirmWithoutRequestIsIgnored() async {
        let (vm, service, _) = makeViewModel()
        vm.password = "hunter2"
        vm.confirmDeletion(notifying: presenter)
        await vm.deletionTask?.value
        #expect(vm.state == .idle)
        #expect(service.callCount == 0)
    }

    // MARK: Submit button enablement

    @Test func cannotSubmitWithEmptyPassword() async {
        let (vm, service, _) = makeViewModel()
        vm.requestDeletion()
        #expect(vm.canSubmit == false)

        vm.confirmDeletion(notifying: presenter)              // tap is ignored
        await vm.deletionTask?.value
        #expect(vm.state == .confirming)
        #expect(service.callCount == 0)
    }

    @Test func whitespaceOnlyPasswordIsAllowedAndSentUntrimmed() async {
        let (vm, service, _) = makeViewModel()
        vm.requestDeletion()
        vm.password = "  "
        #expect(vm.canSubmit)

        vm.confirmDeletion(notifying: presenter)
        await vm.deletionTask?.value
        #expect(service.passwords == ["  "])
    }

    @Test func passesTheTypedPasswordToTheService() async {
        let (vm, service, _) = makeViewModel()
        await submit(vm, password: " correct horse ")
        #expect(service.passwords == [" correct horse "])
    }

    @Test func confirmEntersDeletingSynchronously() async {
        let (vm, _, _) = makeViewModel()
        vm.requestDeletion()
        vm.password = "hunter2"
        vm.confirmDeletion(notifying: presenter)
        // The button must already be disabled + spinning before the network call starts.
        #expect(vm.state == .deleting)
        #expect(vm.isDeleting)
        #expect(vm.canSubmit == false)
        #expect(vm.isSheetPresented)      // stays up (swipe-dismiss disabled) while in flight
        await vm.deletionTask?.value
    }

    @Test func cancelWhileDeletingIsIgnored() async {
        let log = CallLog()
        let gated = GatedAccountService(log: log)
        let vm = AccountDeletionViewModel(accountService: gated, cleanup: MockAccountCleanup(log: log))
        vm.requestDeletion()
        vm.password = "hunter2"
        vm.confirmDeletion(notifying: presenter)
        while !gated.isWaiting { await Task.yield() }

        vm.cancelDeletion()
        #expect(vm.state == .deleting)

        gated.release()
        await vm.deletionTask?.value
        #expect(vm.state == .done)
    }

    // MARK: Success

    @Test func successDeletesOnServerThenCleansUpLocallyThenFinishes() async {
        let (vm, service, cleanup) = makeViewModel()
        await submit(vm)

        #expect(vm.state == .done)
        #expect(vm.isSheetPresented == false)   // sheet dismisses
        #expect(vm.password.isEmpty)
        #expect(service.callCount == 1)
        #expect(cleanup.callCount == 1)
        #expect(log.entries == ["server.delete", "page.present", "local.cleanup"])
    }

    @Test func requestAfterDoneIsIgnored() async {
        let (vm, _, _) = makeViewModel()
        await submit(vm)
        vm.requestDeletion()
        #expect(vm.state == .done)
    }

    // MARK: Failure messages (one per row of the spec's table)

    private func messageAfterFailure(_ error: Error) async -> (AccountDeletionViewModel, MockAccountCleanup) {
        let (vm, service, cleanup) = makeViewModel()
        service.errorToThrow = error
        await submit(vm)
        return (vm, cleanup)
    }

    @Test func wrongPasswordShowsIncorrectPassword() async {
        let (vm, _) = await messageAfterFailure(AccountServiceError.incorrectPassword)
        #expect(vm.errorMessage == "Incorrect password.")
    }

    @Test func rateLimitShowsTooManyAttempts() async {
        let (vm, _) = await messageAfterFailure(AccountServiceError.rateLimited)
        #expect(vm.errorMessage == "Too many attempts. Try again in a few minutes.")
    }

    @Test func serverReauthRequiredAsksForThePasswordAgain() async {
        let (vm, _) = await messageAfterFailure(AccountServiceError.reauthRequired)
        #expect(vm.errorMessage == "Please enter your password again.")
    }

    @Test func networkErrorShowsGenericMessage() async {
        let (vm, _) = await messageAfterFailure(URLError(.notConnectedToInternet))
        #expect(vm.errorMessage == "Couldn't delete your account. Check your connection and try again.")
        #expect(vm.errorMessage == AccountDeletionViewModel.failureMessage)
    }

    @Test func serverRejectedAndNotAuthenticatedShowGenericMessage() async {
        let (vm1, _) = await messageAfterFailure(AccountServiceError.serverRejected(status: 500))
        #expect(vm1.errorMessage == AccountDeletionViewModel.failureMessage)
        let (vm2, _) = await messageAfterFailure(AccountServiceError.notAuthenticated)
        #expect(vm2.errorMessage == AccountDeletionViewModel.failureMessage)
    }

    @Test func failureMessageDoesNotLeakTransportDetails() async {
        struct LeakyError: LocalizedError {
            var errorDescription: String? { "HTTP 500 service_role key=abc" }
        }
        let (vm, _) = await messageAfterFailure(LeakyError())
        #expect(vm.errorMessage == AccountDeletionViewModel.failureMessage)
    }

    @Test func failureKeepsSheetOpenClearsPasswordAndNeverCleansUpLocally() async {
        let (vm, cleanup) = await messageAfterFailure(AccountServiceError.incorrectPassword)
        guard case .failed = vm.state else {
            Issue.record("expected .failed, got \(vm.state)")
            return
        }
        #expect(vm.isSheetPresented)      // error shows inline in the sheet
        #expect(vm.isDeleting == false)
        #expect(vm.password.isEmpty)      // typed password is cleared
        #expect(vm.canSubmit == false)    // until the user types again
        #expect(cleanup.callCount == 0)
        #expect(log.entries == ["server.delete"])
    }

    @Test func retryAfterErrorFromTheSheetSucceeds() async {
        let (vm, service, cleanup) = makeViewModel()
        service.errorToThrow = AccountServiceError.incorrectPassword
        await submit(vm, password: "wrong")
        #expect(vm.errorMessage == "Incorrect password.")

        service.errorToThrow = nil
        vm.password = "right"
        #expect(vm.canSubmit)
        vm.confirmDeletion(notifying: presenter)
        #expect(vm.errorMessage == nil)   // previous error cleared on retry
        await vm.deletionTask?.value

        #expect(vm.state == .done)
        #expect(service.passwords == ["wrong", "right"])
        #expect(cleanup.callCount == 1)
    }

    @Test func cancelAfterErrorReturnsToIdle() async {
        let (vm, service, _) = makeViewModel()
        service.errorToThrow = AccountServiceError.incorrectPassword
        await submit(vm)

        vm.cancelDeletion()
        #expect(vm.state == .idle)
        #expect(vm.errorMessage == nil)
        #expect(vm.isSheetPresented == false)
    }

    @Test func doubleTapWhileDeletingCallsServerOnce() async {
        let log = CallLog()
        let gated = GatedAccountService(log: log)
        let cleanup = MockAccountCleanup(log: log)
        let vm = AccountDeletionViewModel(accountService: gated, cleanup: cleanup)

        vm.requestDeletion()
        vm.password = "hunter2"
        vm.confirmDeletion(notifying: presenter)
        let firstTask = vm.deletionTask

        // Wait until the request is genuinely in flight.
        while !gated.isWaiting { await Task.yield() }

        vm.password = "again"
        vm.confirmDeletion(notifying: presenter)      // second tap — ignored
        vm.requestDeletion()      // and re-requesting mid-flight is ignored too
        #expect(vm.state == .deleting)

        gated.release()
        await firstTask?.value

        #expect(gated.callCount == 1)
        #expect(cleanup.callCount == 1)
        #expect(vm.state == .done)
    }

    // MARK: Account Deleted page (spec D)

    @Test func successPresentsTheAccountDeletedPageOnce() async {
        let (vm, _, _) = makeViewModel()
        await submit(vm)
        #expect(presenter.presentCount == 1)
    }

    /// The page must be up before cleanup ends the session (its last step emits `.signedOut`),
    /// so RootView never has a frame where the user is signed out and the page isn't set.
    @Test func pageIsPresentedAfterServerConfirmsAndBeforeLocalCleanup() async {
        let (vm, _, _) = makeViewModel()
        await submit(vm)
        #expect(log.entries == ["server.delete", "page.present", "local.cleanup"])
    }

    @Test func everyFailureKindNeverPresentsThePage() async {
        struct OtherError: Error {}
        let errors: [Error] = [
            AccountServiceError.incorrectPassword,
            AccountServiceError.rateLimited,
            AccountServiceError.reauthRequired,
            AccountServiceError.notAuthenticated,
            AccountServiceError.serverRejected(status: 403),
            AccountServiceError.serverRejected(status: 500),
            URLError(.notConnectedToInternet),
            OtherError(),
        ]
        for error in errors {
            let (vm, cleanup) = await messageAfterFailure(error)
            #expect(vm.errorMessage != nil, "\(error)")
            #expect(cleanup.callCount == 0, "\(error)")
        }
        #expect(presenter.presentCount == 0)
        #expect(!log.entries.contains("page.present"))
    }

    @Test func cancelNeverPresentsThePage() {
        let (vm, _, _) = makeViewModel()
        vm.requestDeletion()
        vm.password = "typed"
        vm.cancelDeletion()
        #expect(presenter.presentCount == 0)
    }

    @Test func retryAfterFailurePresentsThePageOnlyOnSuccess() async {
        let (vm, service, _) = makeViewModel()
        service.errorToThrow = AccountServiceError.incorrectPassword
        await submit(vm, password: "wrong")
        #expect(presenter.presentCount == 0)

        service.errorToThrow = nil
        await submit(vm, password: "right")
        #expect(presenter.presentCount == 1)
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

// MARK: - Post-deletion routing (spec D)

@Suite("PostDeletionRouting")
@MainActor
struct PostDeletionRoutingTests {

    @Test func defaultsToNoPageAndTheTour() {
        let routing = PostDeletionRouting()
        #expect(routing.isShowingAccountDeleted == false)
        #expect(routing.onboardingStart == .tour)
    }

    @Test func accountDeletedShowsThePage() {
        var routing = PostDeletionRouting()
        routing.accountDeleted()
        #expect(routing.isShowingAccountDeleted)
    }

    @Test func backToSignInClearsThePageAndStartsOnboardingAtAuth() {
        var routing = PostDeletionRouting()
        routing.accountDeleted()
        routing.backToSignIn()
        #expect(routing.isShowingAccountDeleted == false)
        #expect(routing.onboardingStart == .auth)
    }

    /// The tour is skipped only for the sign-in that follows a deletion; a later sign-out in
    /// the same process starts at the tour again.
    @Test func signingInRestoresTheTourDefault() {
        var routing = PostDeletionRouting()
        routing.accountDeleted()
        routing.backToSignIn()
        routing.signedIn()
        #expect(routing.onboardingStart == .tour)
        #expect(routing.isShowingAccountDeleted == false)
    }
}

@Suite("RootView screen selection")
@MainActor
struct RootViewScreenTests {

    private func screen(
        isLoading: Bool = false,
        showsDeleted: Bool = false,
        isAuthenticated: Bool = true,
        onboardingComplete: Bool = true
    ) -> RootView.Screen {
        RootView.screen(
            isLoading: isLoading,
            isShowingAccountDeleted: showsDeleted,
            isAuthenticated: isAuthenticated,
            onboardingComplete: onboardingComplete
        )
    }

    @Test func signedInAndOnboardedShowsTheApp() {
        #expect(screen() == .main)
    }

    @Test func signedOutOrNotOnboardedShowsOnboarding() {
        #expect(screen(isAuthenticated: false) == .onboarding)
        #expect(screen(onboardingComplete: false) == .onboarding)
    }

    @Test func loadingShowsTheSpinner() {
        #expect(screen(isLoading: true, isAuthenticated: false) == .loading)
    }

    /// No tour flash: the page wins over every auth / onboarding combination the cleanup
    /// passes through (still signed in → onboarding reset → signed out).
    @Test func accountDeletedPageWinsOverAuthAndOnboardingState() {
        for auth in [true, false] {
            for onboarded in [true, false] {
                #expect(screen(showsDeleted: true, isAuthenticated: auth, onboardingComplete: onboarded) == .accountDeleted)
            }
        }
    }
}

@Suite("OnboardingCoordinator start step")
@MainActor
struct OnboardingCoordinatorStartTests {

    @Test func defaultStartIsTheTour() {
        let coordinator = OnboardingCoordinator(onboardingComplete: .constant(false))
        #expect(coordinator.initialStep == .tour)
    }

    @Test func canStartAtAuth() {
        let coordinator = OnboardingCoordinator(onboardingComplete: .constant(false), startingAt: .auth)
        #expect(coordinator.initialStep == .auth)
    }
}

// MARK: - AccountService (re-auth → delete-account)

@Suite("AccountService")
@MainActor
struct AccountServiceTests {

    private let log = CallLog()

    private func makeService(
        email: String? = "ada@example.com",
        token: String = "fresh-token"
    ) -> (AccountService, MockReauthenticator, MockDeleteFunction) {
        let auth = MockReauthenticator(log: log, email: email, token: token)
        let function = MockDeleteFunction(log: log)
        return (AccountService(auth: auth, deleteFunction: function), auth, function)
    }

    @Test func reauthenticatesWithSessionEmailAndPasswordBeforeDeleting() async throws {
        let (service, auth, _) = makeService()
        try await service.deleteAccount(password: "hunter2")
        #expect(auth.signIns.count == 1)
        #expect(auth.signIns.first?.email == "ada@example.com")
        #expect(auth.signIns.first?.password == "hunter2")
        #expect(log.entries == ["auth.signIn", "function.delete"])
    }

    @Test func deleteCallUsesTheTokenFromReauthentication() async throws {
        let (service, _, function) = makeService(token: "token-from-reauth")
        try await service.deleteAccount(password: "hunter2")
        #expect(function.tokens == ["token-from-reauth"])
    }

    @Test func passwordIsSentUntrimmed() async throws {
        let (service, auth, _) = makeService()
        try await service.deleteAccount(password: "  pw  ")
        #expect(auth.signIns.first?.password == "  pw  ")
    }

    @Test func noSignedInEmailThrowsNotAuthenticatedAndSendsNothing() async {
        let (service, auth, function) = makeService(email: nil)
        await #expect(throws: AccountServiceError.notAuthenticated) {
            try await service.deleteAccount(password: "hunter2")
        }
        #expect(auth.signIns.isEmpty)
        #expect(function.tokens.isEmpty)
    }

    @Test func emptyEmailThrowsNotAuthenticatedAndSendsNothing() async {
        let (service, auth, function) = makeService(email: "")
        await #expect(throws: AccountServiceError.notAuthenticated) {
            try await service.deleteAccount(password: "hunter2")
        }
        #expect(auth.signIns.isEmpty)
        #expect(function.tokens.isEmpty)
    }

    @Test func wrongPasswordThrowsIncorrectPasswordAndSkipsDelete() async {
        let (service, auth, function) = makeService()
        auth.errorToThrow = authAPIError(code: .invalidCredentials, status: 400)
        await #expect(throws: AccountServiceError.incorrectPassword) {
            try await service.deleteAccount(password: "wrong")
        }
        #expect(function.tokens.isEmpty)
        #expect(log.entries == ["auth.signIn"])
    }

    @Test func authRateLimitCodeThrowsRateLimited() async {
        let (service, auth, function) = makeService()
        auth.errorToThrow = authAPIError(code: .overRequestRateLimit, status: 429)
        await #expect(throws: AccountServiceError.rateLimited) {
            try await service.deleteAccount(password: "hunter2")
        }
        #expect(function.tokens.isEmpty)
    }

    @Test func authHTTP429WithoutCodeThrowsRateLimited() async {
        let (service, auth, _) = makeService()
        auth.errorToThrow = authAPIError(code: .unknown, status: 429)
        await #expect(throws: AccountServiceError.rateLimited) {
            try await service.deleteAccount(password: "hunter2")
        }
    }

    @Test func otherAuthErrorPassesThroughAndSkipsDelete() async {
        let (service, auth, function) = makeService()
        auth.errorToThrow = URLError(.notConnectedToInternet)
        await #expect(throws: URLError.self) {
            try await service.deleteAccount(password: "hunter2")
        }
        #expect(function.tokens.isEmpty)
    }

    @Test func serverReauthRequiredThrowsReauthRequired() async {
        let (service, _, function) = makeService()
        function.errorToThrow = FunctionsError.httpError(
            code: 403, data: Data(#"{"error":"reauth_required"}"#.utf8)
        )
        await #expect(throws: AccountServiceError.reauthRequired) {
            try await service.deleteAccount(password: "hunter2")
        }
    }

    @Test func server403WithOtherBodyIsServerRejected() async {
        let (service, _, function) = makeService()
        function.errorToThrow = FunctionsError.httpError(code: 403, data: Data("forbidden".utf8))
        await #expect(throws: AccountServiceError.serverRejected(status: 403)) {
            try await service.deleteAccount(password: "hunter2")
        }
    }

    @Test func server500IsServerRejected() async {
        let (service, _, function) = makeService()
        function.errorToThrow = FunctionsError.httpError(
            code: 500, data: Data(#"{"error":"Account deletion failed"}"#.utf8)
        )
        await #expect(throws: AccountServiceError.serverRejected(status: 500)) {
            try await service.deleteAccount(password: "hunter2")
        }
    }
}

// MARK: - AccountServiceError mapping

@Suite("AccountServiceError")
@MainActor
struct AccountServiceErrorTests {

    @Test func mapsFunctionHTTPErrorToServerRejected() {
        let mapped = AccountServiceError.mapFunctionError(FunctionsError.httpError(code: 500, data: Data()))
        #expect(mapped as? AccountServiceError == .serverRejected(status: 500))
    }

    @Test func mapsUnauthorizedToServerRejected401() {
        let mapped = AccountServiceError.mapFunctionError(FunctionsError.httpError(code: 401, data: Data()))
        #expect(mapped as? AccountServiceError == .serverRejected(status: 401))
    }

    @Test func mapsReauthRequired403() {
        let mapped = AccountServiceError.mapFunctionError(
            FunctionsError.httpError(code: 403, data: Data(#"{"error":"reauth_required"}"#.utf8))
        )
        #expect(mapped as? AccountServiceError == .reauthRequired)
    }

    @Test func reauthRequiredBodyOnAnotherStatusIsNotReauth() {
        let mapped = AccountServiceError.mapFunctionError(
            FunctionsError.httpError(code: 500, data: Data(#"{"error":"reauth_required"}"#.utf8))
        )
        #expect(mapped as? AccountServiceError == .serverRejected(status: 500))
    }

    @Test func functionPassesThroughOtherErrors() {
        let mapped = AccountServiceError.mapFunctionError(URLError(.notConnectedToInternet))
        #expect(mapped is URLError)
    }

    @Test func mapsInvalidCredentials() {
        let mapped = AccountServiceError.mapSignInError(authAPIError(code: .invalidCredentials, status: 400))
        #expect(mapped as? AccountServiceError == .incorrectPassword)
    }

    @Test func mapsRateLimitByCodeOrStatus() {
        let byCode = AccountServiceError.mapSignInError(authAPIError(code: .overRequestRateLimit, status: 429))
        #expect(byCode as? AccountServiceError == .rateLimited)
        let byStatus = AccountServiceError.mapSignInError(authAPIError(code: .unknown, status: 429))
        #expect(byStatus as? AccountServiceError == .rateLimited)
    }

    @Test func otherAuthAPIErrorPassesThrough() {
        let mapped = AccountServiceError.mapSignInError(authAPIError(code: .unexpectedFailure, status: 500))
        #expect(!(mapped is AccountServiceError))
    }

    @Test func signInPassesThroughNetworkErrors() {
        let mapped = AccountServiceError.mapSignInError(URLError(.timedOut))
        #expect(mapped is URLError)
    }

    @Test func everyCaseHasADescription() {
        let all: [AccountServiceError] = [
            .notAuthenticated, .incorrectPassword, .rateLimited, .reauthRequired,
            .serverRejected(status: 500),
        ]
        for error in all {
            #expect(error.errorDescription != nil)
        }
    }
}

/// A Supabase Auth API error as `signIn(email:password:)` throws it.
private func authAPIError(code: ErrorCode, status: Int) -> Error {
    let response = HTTPURLResponse(
        url: URL(string: "https://example.supabase.co/auth/v1/token")!,
        statusCode: status,
        httpVersion: nil,
        headerFields: nil
    )!
    // `Auth.` qualifies past the app's own `AuthError` enum (AuthService.swift).
    return Auth.AuthError.api(
        message: "error", errorCode: code, underlyingData: Data(), underlyingResponse: response
    )
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

// MARK: - Mocks

@MainActor
private final class CallLog {
    var entries: [String] = []
}

@MainActor
private final class MockAccountService: AccountServiceProtocol {
    let log: CallLog
    var callCount = 0
    var passwords: [String] = []
    var errorToThrow: Error?

    init(log: CallLog) { self.log = log }

    func deleteAccount(password: String) async throws {
        callCount += 1
        passwords.append(password)
        log.entries.append("server.delete")
        if let errorToThrow { throw errorToThrow }
    }
}

/// Suspends inside `deleteAccount(password:)` until `release()` so a test can act mid-flight.
@MainActor
private final class GatedAccountService: AccountServiceProtocol {
    let log: CallLog
    var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    init(log: CallLog) { self.log = log }

    func deleteAccount(password: String) async throws {
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
private final class MockReauthenticator: PasswordReauthenticating {
    let log: CallLog
    let email: String?
    let token: String
    var signIns: [(email: String, password: String)] = []
    var errorToThrow: Error?

    init(log: CallLog, email: String?, token: String) {
        self.log = log
        self.email = email
        self.token = token
    }

    func currentUserEmail() -> String? { email }

    func signIn(email: String, password: String) async throws -> String {
        signIns.append((email, password))
        log.entries.append("auth.signIn")
        if let errorToThrow { throw errorToThrow }
        return token
    }
}

@MainActor
private final class MockDeleteFunction: DeleteAccountFunctionInvoking {
    let log: CallLog
    var tokens: [String] = []
    var errorToThrow: Error?

    init(log: CallLog) { self.log = log }

    func invoke(accessToken: String) async throws {
        tokens.append(accessToken)
        log.entries.append("function.delete")
        if let errorToThrow { throw errorToThrow }
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
private final class MockAccountDeletedPresenter: AccountDeletedPresenting {
    let log: CallLog
    var presentCount = 0

    init(log: CallLog) { self.log = log }

    func presentAccountDeleted() {
        presentCount += 1
        log.entries.append("page.present")
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

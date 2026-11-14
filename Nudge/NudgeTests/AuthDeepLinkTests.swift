import Testing
import Foundation
@testable import Nudge

// MARK: - URL routing

@Suite("AuthDeepLink routing")
@MainActor
struct AuthDeepLinkRoutingTests {

    private func route(_ string: String) -> AuthDeepLink? {
        AuthDeepLink(url: URL(string: string)!)
    }

    @Test func recoveryWithPKCECodeQuery() {
        #expect(route("nudge://reset-password?code=abc123") == .passwordRecovery)
    }

    @Test func recoveryWithFragmentParams() {
        #expect(route("nudge://reset-password#access_token=x&refresh_token=y&type=recovery") == .passwordRecovery)
    }

    @Test func recoveryWithNoParams() {
        #expect(route("nudge://reset-password") == .passwordRecovery)
    }

    @Test func recoveryWithTrailingSlash() {
        #expect(route("nudge://reset-password/?code=abc") == .passwordRecovery)
    }

    @Test func confirmationWithPKCECodeQuery() {
        #expect(route("nudge://auth-callback?code=abc123") == .emailConfirmation)
    }

    @Test func confirmationWithErrorFragment() {
        // Expired links still route here; session(from:) is what rejects them.
        #expect(route("nudge://auth-callback#error=access_denied&error_code=otp_expired") == .emailConfirmation)
    }

    @Test func uppercaseSchemeAndHostRoute() {
        // RFC 3986: scheme and host are case-insensitive.
        #expect(route("NUDGE://RESET-PASSWORD?code=abc") == .passwordRecovery)
        #expect(route("Nudge://Auth-Callback?code=abc") == .emailConfirmation)
    }

    @Test func wrongSchemeIsIgnored() {
        #expect(route("https://reset-password?code=abc") == nil)
        #expect(route("otherapp://reset-password?code=abc") == nil)
        #expect(route("https://example.com/auth-callback?code=abc") == nil)
    }

    @Test func wrongHostIsIgnored() {
        #expect(route("nudge://settings") == nil)
        #expect(route("nudge://reset-password-evil?code=abc") == nil)
        #expect(route("nudge://") == nil)
    }

    @Test func unexpectedPathIsIgnored() {
        #expect(route("nudge://reset-password/extra?code=abc") == nil)
        #expect(route("nudge://auth-callback/x") == nil)
    }

    @Test func missingHostIsIgnored() {
        #expect(route("nudge:reset-password") == nil)
    }

    @Test func redirectURLsMatchRegisteredScheme() {
        #expect(AuthDeepLink.passwordRecovery.redirectURL.absoluteString == "nudge://reset-password")
        #expect(AuthDeepLink.emailConfirmation.redirectURL.absoluteString == "nudge://auth-callback")
    }

    @Test func redirectURLsRoundTrip() {
        for link in [AuthDeepLink.passwordRecovery, .emailConfirmation] {
            #expect(AuthDeepLink(url: link.redirectURL) == link)
        }
    }
}

// MARK: - Password rules

@Suite("Password rules")
@MainActor
struct PasswordRulesTests {

    @Test func minimumLengthIsEight() {
        #expect(PasswordRules.minimumLength == 8)
    }

    @Test func tooShortIsRejected() {
        #expect(PasswordRules.validationError(password: "1234567", confirmation: "1234567") == PasswordRules.tooShortMessage)
    }

    @Test func emptyIsRejectedAsTooShort() {
        #expect(PasswordRules.validationError(password: "", confirmation: "") == PasswordRules.tooShortMessage)
    }

    @Test func mismatchIsRejected() {
        #expect(PasswordRules.validationError(password: "longenough1", confirmation: "longenough2") == PasswordRules.mismatchMessage)
    }

    @Test func lengthCheckedBeforeMatch() {
        #expect(PasswordRules.validationError(password: "short", confirmation: "other") == PasswordRules.tooShortMessage)
    }

    @Test func exactlyEightAndMatchingIsAccepted() {
        #expect(PasswordRules.validationError(password: "12345678", confirmation: "12345678") == nil)
    }
}

// MARK: - Email validation

@Suite("Email validation")
@MainActor
struct EmailValidationTests {

    @Test func validAddressesPass() {
        #expect("a@b.co".isValidEmail)
        #expect("first.last+tag@sub.example.org".isValidEmail)
        #expect("USER@EXAMPLE.COM".isValidEmail)
    }

    @Test func invalidAddressesFail() {
        #expect("".isValidEmail == false)
        #expect("plainaddress".isValidEmail == false)
        #expect("a@b".isValidEmail == false)
        #expect("a@.com".isValidEmail == false)
        #expect("a@b.c".isValidEmail == false)
        #expect("a b@c.com".isValidEmail == false)
        #expect("@example.com".isValidEmail == false)
    }

    @Test func surroundingWhitespaceFails() {
        // Trimming is the caller's job (at submit time), not the validator's.
        #expect(" a@b.co ".isValidEmail == false)
    }
}

// MARK: - Rate-limit classification

@Suite("Auth rate-limit classification")
@MainActor
struct AuthRateLimitTests {

    @Test func emailSendRateLimitCode() {
        #expect(AuthRateLimit.isRateLimited(errorCode: "over_email_send_rate_limit", httpStatus: 429))
    }

    @Test func requestRateLimitCode() {
        #expect(AuthRateLimit.isRateLimited(errorCode: "over_request_rate_limit", httpStatus: nil))
    }

    @Test func http429WithoutCode() {
        #expect(AuthRateLimit.isRateLimited(errorCode: nil, httpStatus: 429))
    }

    @Test func otherErrorsAreNotRateLimits() {
        #expect(AuthRateLimit.isRateLimited(errorCode: "validation_failed", httpStatus: 400) == false)
        #expect(AuthRateLimit.isRateLimited(errorCode: "unknown", httpStatus: 500) == false)
        #expect(AuthRateLimit.isRateLimited(errorCode: nil, httpStatus: nil) == false)
    }
}

// MARK: - Forgot password ViewModel

@Suite("ForgotPasswordViewModel")
@MainActor
struct ForgotPasswordViewModelTests {

    @Test func prefillsEmail() {
        let vm = ForgotPasswordViewModel(email: "grace@example.com", service: MockAuthRecoveryService())
        #expect(vm.email == "grace@example.com")
        #expect(vm.status == .idle)
        #expect(vm.statusMessage == nil)
    }

    @Test func invalidEmailDoesNotCallService() async {
        let mock = MockAuthRecoveryService()
        let vm = ForgotPasswordViewModel(email: "not-an-email", service: mock)

        await vm.submit()

        #expect(mock.resetEmails.isEmpty)
        #expect(vm.validationError == ForgotPasswordViewModel.invalidEmailMessage)
        #expect(vm.status == .idle)
    }

    @Test func successShowsNeutralMessageAndTrimsEmail() async {
        let mock = MockAuthRecoveryService()
        let vm = ForgotPasswordViewModel(email: "  grace@example.com \n", service: mock)

        await vm.submit()

        #expect(mock.resetEmails == ["grace@example.com"])
        #expect(vm.status == .sent)
        #expect(vm.statusMessage == ForgotPasswordViewModel.neutralMessage)
        #expect(vm.validationError == nil)
        #expect(vm.isSending == false)
    }

    @Test func neutralMessageWording() {
        #expect(ForgotPasswordViewModel.neutralMessage == "If an account exists for that email, we've sent a reset link.")
        #expect(ForgotPasswordViewModel.rateLimitedMessage == "Please wait a minute before trying again.")
    }

    @Test func rateLimitShowsWaitMessage() async {
        let mock = MockAuthRecoveryService()
        mock.resetError = AuthError.rateLimited
        let vm = ForgotPasswordViewModel(email: "grace@example.com", service: mock)

        await vm.submit()

        #expect(vm.status == .rateLimited)
        #expect(vm.statusMessage == ForgotPasswordViewModel.rateLimitedMessage)
    }

    @Test func serverErrorIsSwallowedIntoNeutralMessage() async {
        // No account enumeration: any server-side failure looks like success.
        let mock = MockAuthRecoveryService()
        mock.resetError = NSError(domain: "server", code: 500)
        let vm = ForgotPasswordViewModel(email: "nobody@example.com", service: mock)

        await vm.submit()

        #expect(vm.status == .sent)
        #expect(vm.statusMessage == ForgotPasswordViewModel.neutralMessage)
    }

    @Test func transportErrorShowsConnectionMessage() async {
        // A transport failure never reached the server, so it reveals nothing about the account.
        let mock = MockAuthRecoveryService()
        mock.resetError = URLError(.notConnectedToInternet)
        let vm = ForgotPasswordViewModel(email: "grace@example.com", service: mock)

        await vm.submit()

        #expect(vm.status == .offline)
        #expect(vm.statusMessage == ForgotPasswordViewModel.offlineMessage)
    }

    @Test func resubmitClearsPreviousValidationError() async {
        let mock = MockAuthRecoveryService()
        let vm = ForgotPasswordViewModel(email: "bad", service: mock)
        await vm.submit()
        #expect(vm.validationError != nil)

        vm.email = "grace@example.com"
        await vm.submit()

        #expect(vm.validationError == nil)
        #expect(vm.status == .sent)
    }

    @Test func cannotSubmitBlankEmail() {
        let vm = ForgotPasswordViewModel(email: "   ", service: MockAuthRecoveryService())
        #expect(vm.canSubmit == false)
    }
}

// MARK: - Set new password ViewModel

@Suite("SetNewPasswordViewModel")
@MainActor
struct SetNewPasswordViewModelTests {

    @Test func tooShortDoesNotCallService() async {
        let mock = MockAuthRecoveryService()
        let vm = SetNewPasswordViewModel(service: mock)
        vm.newPassword = "short"
        vm.confirmPassword = "short"

        await vm.save()

        #expect(mock.updatedPasswords.isEmpty)
        #expect(vm.errorMessage == PasswordRules.tooShortMessage)
        #expect(vm.didSucceed == false)
    }

    @Test func mismatchDoesNotCallService() async {
        let mock = MockAuthRecoveryService()
        let vm = SetNewPasswordViewModel(service: mock)
        vm.newPassword = "longenough1"
        vm.confirmPassword = "longenough2"

        await vm.save()

        #expect(mock.updatedPasswords.isEmpty)
        #expect(vm.errorMessage == PasswordRules.mismatchMessage)
    }

    @Test func validPasswordUpdatesAndSucceeds() async {
        let mock = MockAuthRecoveryService()
        let vm = SetNewPasswordViewModel(service: mock)
        vm.newPassword = " spaces count "
        vm.confirmPassword = " spaces count "

        await vm.save()

        // Passwords are never trimmed — whitespace is a legitimate character.
        #expect(mock.updatedPasswords == [" spaces count "])
        #expect(vm.didSucceed)
        #expect(vm.errorMessage == nil)
        #expect(vm.isSaving == false)
    }

    @Test func serviceFailureSurfacesError() async {
        let mock = MockAuthRecoveryService()
        mock.updateError = AuthError.notAuthenticated
        let vm = SetNewPasswordViewModel(service: mock)
        vm.newPassword = "longenough1"
        vm.confirmPassword = "longenough1"

        await vm.save()

        #expect(vm.didSucceed == false)
        #expect(vm.errorMessage == AuthError.notAuthenticated.localizedDescription)
        #expect(vm.isSaving == false)
    }

    @Test func canSubmitRequiresBothFields() {
        let vm = SetNewPasswordViewModel(service: MockAuthRecoveryService())
        #expect(vm.canSubmit == false)
        vm.newPassword = "longenough1"
        #expect(vm.canSubmit == false)
        vm.confirmPassword = "x"
        #expect(vm.canSubmit)
    }
}

// MARK: - Coordinator (deep link → sheet / alert)

@Suite("AuthRecoveryCoordinator")
@MainActor
struct AuthRecoveryCoordinatorTests {

    private let recoveryURL = URL(string: "nudge://reset-password?code=abc")!
    private let confirmationURL = URL(string: "nudge://auth-callback?code=abc")!

    @Test func presentForgotPasswordCarriesPrefill() {
        let coordinator = AuthRecoveryCoordinator(service: MockAuthRecoveryService())
        coordinator.presentForgotPassword(prefillEmail: "grace@example.com")
        #expect(coordinator.activeSheet == .forgotPassword(prefillEmail: "grace@example.com"))
    }

    @Test func recoveryLinkExchangesSessionAndPresentsSetPassword() async {
        let mock = MockAuthRecoveryService()
        let coordinator = AuthRecoveryCoordinator(service: mock)

        await coordinator.handleOpenURL(recoveryURL)

        #expect(mock.exchangedURLs == [recoveryURL])
        #expect(coordinator.activeSheet == .setNewPassword)
        #expect(coordinator.isShowingExpiredLinkAlert == false)
    }

    @Test func recoveryLinkReplacesOpenForgotPasswordSheet() async {
        let coordinator = AuthRecoveryCoordinator(service: MockAuthRecoveryService())
        coordinator.presentForgotPassword(prefillEmail: "")

        await coordinator.handleOpenURL(recoveryURL)

        #expect(coordinator.activeSheet == .setNewPassword)
    }

    @Test func confirmationLinkExchangesSessionWithoutSheet() async {
        let mock = MockAuthRecoveryService()
        let coordinator = AuthRecoveryCoordinator(service: mock)

        await coordinator.handleOpenURL(confirmationURL)

        #expect(mock.exchangedURLs == [confirmationURL])
        #expect(coordinator.activeSheet == nil)
        #expect(coordinator.isShowingExpiredLinkAlert == false)
    }

    @Test func confirmationLinkClosesForgotPasswordSheet() async {
        let coordinator = AuthRecoveryCoordinator(service: MockAuthRecoveryService())
        coordinator.presentForgotPassword(prefillEmail: "")

        await coordinator.handleOpenURL(confirmationURL)

        #expect(coordinator.activeSheet == nil)
    }

    @Test func unrelatedURLIsIgnored() async {
        let mock = MockAuthRecoveryService()
        let coordinator = AuthRecoveryCoordinator(service: mock)

        await coordinator.handleOpenURL(URL(string: "https://example.com/reset-password?code=abc")!)
        await coordinator.handleOpenURL(URL(string: "nudge://settings")!)

        #expect(mock.exchangedURLs.isEmpty)
        #expect(coordinator.activeSheet == nil)
        #expect(coordinator.isShowingExpiredLinkAlert == false)
    }

    @Test func expiredLinkShowsAlert() async {
        let mock = MockAuthRecoveryService()
        mock.exchangeError = NSError(domain: "auth", code: 403)
        let coordinator = AuthRecoveryCoordinator(service: mock)

        await coordinator.handleOpenURL(recoveryURL)

        #expect(coordinator.activeSheet == nil)
        #expect(coordinator.isShowingExpiredLinkAlert)
        #expect(AuthRecoveryCoordinator.expiredLinkMessage == "This link has expired. Request a new one.")
    }

    @Test func expiredConfirmationLinkShowsAlert() async {
        let mock = MockAuthRecoveryService()
        mock.exchangeError = NSError(domain: "auth", code: 403)
        let coordinator = AuthRecoveryCoordinator(service: mock)

        await coordinator.handleOpenURL(confirmationURL)

        #expect(coordinator.isShowingExpiredLinkAlert)
    }

    @Test func expiredLinkWithForgotSheetOpenAlertsAfterDismiss() async {
        // An alert can't be presented while a sheet is up, so the coordinator
        // closes the sheet first and raises the alert from the sheet's onDismiss.
        let mock = MockAuthRecoveryService()
        mock.exchangeError = NSError(domain: "auth", code: 403)
        let coordinator = AuthRecoveryCoordinator(service: mock)
        coordinator.presentForgotPassword(prefillEmail: "")

        await coordinator.handleOpenURL(recoveryURL)

        #expect(coordinator.activeSheet == nil)
        #expect(coordinator.isShowingExpiredLinkAlert == false)

        coordinator.sheetDidDismiss()

        #expect(coordinator.isShowingExpiredLinkAlert)
    }

    @Test func expiredLinkDoesNotInterruptSetPasswordInProgress() async {
        let mock = MockAuthRecoveryService()
        let coordinator = AuthRecoveryCoordinator(service: mock)
        await coordinator.handleOpenURL(recoveryURL)
        #expect(coordinator.activeSheet == .setNewPassword)

        mock.exchangeError = NSError(domain: "auth", code: 403)
        await coordinator.handleOpenURL(recoveryURL)

        #expect(coordinator.activeSheet == .setNewPassword)
        #expect(coordinator.isShowingExpiredLinkAlert == false)
    }

    @Test func plainDismissDoesNotRaiseAlert() {
        let coordinator = AuthRecoveryCoordinator(service: MockAuthRecoveryService())
        coordinator.presentForgotPassword(prefillEmail: "")
        coordinator.dismissSheet()
        coordinator.sheetDidDismiss()

        #expect(coordinator.activeSheet == nil)
        #expect(coordinator.isShowingExpiredLinkAlert == false)
    }
}

// MARK: - Mock

private final class MockAuthRecoveryService: AuthRecoveryServiceProtocol {
    var resetError: Error?
    var exchangeError: Error?
    var updateError: Error?

    var resetEmails: [String] = []
    var exchangedURLs: [URL] = []
    var updatedPasswords: [String] = []

    func sendPasswordReset(email: String) async throws {
        resetEmails.append(email)
        if let resetError { throw resetError }
    }

    func establishSession(from url: URL) async throws {
        exchangedURLs.append(url)
        if let exchangeError { throw exchangeError }
    }

    func updatePassword(_ newPassword: String) async throws {
        updatedPasswords.append(newPassword)
        if let updateError { throw updateError }
    }
}

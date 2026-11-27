import Testing
import Foundation
import Supabase
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
        #expect(coordinator.isShowingLinkAlert == false)
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
        #expect(coordinator.isShowingLinkAlert == false)
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
        #expect(coordinator.isShowingLinkAlert == false)
    }

    @Test func expiredLinkShowsAlert() async {
        let mock = MockAuthRecoveryService()
        mock.exchangeError = NSError(domain: "auth", code: 403)
        let coordinator = AuthRecoveryCoordinator(service: mock)

        await coordinator.handleOpenURL(recoveryURL)

        #expect(coordinator.activeSheet == nil)
        #expect(coordinator.isShowingLinkAlert)
        // An unrecognised error falls back to the "expired" message.
        #expect(coordinator.linkAlertMessage == "This link has expired. Request a new one.")
    }

    @Test func expiredConfirmationLinkShowsAlert() async {
        let mock = MockAuthRecoveryService()
        mock.exchangeError = NSError(domain: "auth", code: 403)
        let coordinator = AuthRecoveryCoordinator(service: mock)

        await coordinator.handleOpenURL(confirmationURL)

        #expect(coordinator.isShowingLinkAlert)
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
        #expect(coordinator.isShowingLinkAlert == false)

        coordinator.sheetDidDismiss()

        #expect(coordinator.isShowingLinkAlert)
    }

    @Test func expiredLinkDoesNotInterruptSetPasswordInProgress() async {
        let mock = MockAuthRecoveryService()
        let coordinator = AuthRecoveryCoordinator(service: mock)
        await coordinator.handleOpenURL(recoveryURL)
        #expect(coordinator.activeSheet == .setNewPassword)

        mock.exchangeError = NSError(domain: "auth", code: 403)
        await coordinator.handleOpenURL(recoveryURL)

        #expect(coordinator.activeSheet == .setNewPassword)
        #expect(coordinator.isShowingLinkAlert == false)
    }

    @Test func plainDismissDoesNotRaiseAlert() {
        let coordinator = AuthRecoveryCoordinator(service: MockAuthRecoveryService())
        coordinator.presentForgotPassword(prefillEmail: "")
        coordinator.dismissSheet()
        coordinator.sheetDidDismiss()

        #expect(coordinator.activeSheet == nil)
        #expect(coordinator.isShowingLinkAlert == false)
    }
}

// MARK: - Coordinator: specific link-failure messages (spec C2)

@Suite("AuthRecoveryCoordinator link failures")
@MainActor
struct AuthRecoveryCoordinatorLinkFailureTests {

    private let otpExpiredQuery = URL(string: "nudge://reset-password?error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired")!
    private let otpExpiredFragment = URL(string: "nudge://auth-callback#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired&sb=")!
    private let recoveryURL = URL(string: "nudge://reset-password?code=abc")!
    private let confirmationURL = URL(string: "nudge://auth-callback?code=abc")!

    @Test func redirectErrorInQueryAlertsWithoutCallingSupabase() async {
        let mock = MockAuthRecoveryService()
        let coordinator = AuthRecoveryCoordinator(service: mock)

        await coordinator.handleOpenURL(otpExpiredQuery)

        #expect(mock.exchangedURLs.isEmpty)
        #expect(coordinator.isShowingLinkAlert)
        #expect(coordinator.linkAlertMessage == AuthLinkFailure.expiredMessage)
    }

    @Test func redirectErrorInFragmentAlertsWithoutCallingSupabase() async {
        let mock = MockAuthRecoveryService()
        let coordinator = AuthRecoveryCoordinator(service: mock)

        await coordinator.handleOpenURL(otpExpiredFragment)

        #expect(mock.exchangedURLs.isEmpty)
        #expect(coordinator.isShowingLinkAlert)
        #expect(coordinator.linkAlertMessage == AuthLinkFailure.expiredMessage)
    }

    @Test func malformedLinkAlertsWithoutCallingSupabase() async {
        let mock = MockAuthRecoveryService()
        let coordinator = AuthRecoveryCoordinator(service: mock)

        await coordinator.handleOpenURL(URL(string: "nudge://reset-password")!)

        #expect(mock.exchangedURLs.isEmpty)
        #expect(coordinator.isShowingLinkAlert)
        #expect(coordinator.linkAlertMessage == AuthLinkFailure.malformedMessage)
    }

    @Test func differentDeviceRecoveryMessage() async {
        let mock = MockAuthRecoveryService()
        mock.exchangeError = authAPIError(code: .validationFailed, status: 400)
        let coordinator = AuthRecoveryCoordinator(service: mock)

        await coordinator.handleOpenURL(recoveryURL)

        #expect(mock.exchangedURLs == [recoveryURL])
        #expect(coordinator.linkAlertMessage == AuthLinkFailure.differentDeviceResetMessage)
    }

    @Test func differentDeviceConfirmationMessage() async {
        let mock = MockAuthRecoveryService()
        mock.exchangeError = authAPIError(code: .validationFailed, status: 400)
        let coordinator = AuthRecoveryCoordinator(service: mock)

        await coordinator.handleOpenURL(confirmationURL)

        #expect(coordinator.linkAlertMessage == AuthLinkFailure.confirmedSignInMessage)
    }

    @Test func olderRequestMessage() async {
        let mock = MockAuthRecoveryService()
        mock.exchangeError = authAPIError(code: .badCodeVerifier, status: 400)
        let coordinator = AuthRecoveryCoordinator(service: mock)

        await coordinator.handleOpenURL(recoveryURL)

        #expect(coordinator.linkAlertMessage == AuthLinkFailure.olderRequestMessage)
    }

    @Test func offlineMessage() async {
        let mock = MockAuthRecoveryService()
        mock.exchangeError = URLError(.notConnectedToInternet)
        let coordinator = AuthRecoveryCoordinator(service: mock)

        await coordinator.handleOpenURL(confirmationURL)

        #expect(coordinator.linkAlertMessage == AuthLinkFailure.offlineMessage)
    }

    @Test func redirectErrorWithForgotSheetOpenAlertsAfterDismiss() async {
        let coordinator = AuthRecoveryCoordinator(service: MockAuthRecoveryService())
        coordinator.presentForgotPassword(prefillEmail: "")

        await coordinator.handleOpenURL(otpExpiredQuery)

        #expect(coordinator.activeSheet == nil)
        #expect(coordinator.isShowingLinkAlert == false)

        coordinator.sheetDidDismiss()

        #expect(coordinator.isShowingLinkAlert)
        #expect(coordinator.linkAlertMessage == AuthLinkFailure.expiredMessage)
    }

    @Test func redirectErrorDoesNotInterruptSetPasswordInProgress() async {
        let mock = MockAuthRecoveryService()
        let coordinator = AuthRecoveryCoordinator(service: mock)
        await coordinator.handleOpenURL(recoveryURL)
        #expect(coordinator.activeSheet == .setNewPassword)

        await coordinator.handleOpenURL(otpExpiredQuery)

        #expect(coordinator.activeSheet == .setNewPassword)
        #expect(coordinator.isShowingLinkAlert == false)
    }

    @Test func alertTitle() {
        #expect(AuthLinkFailure.alertTitle == "Link Problem")
    }
}

// MARK: - Link failure: redirect URL parsing (spec C2)

@Suite("AuthLinkFailure redirect parsing")
@MainActor
struct AuthLinkFailureRedirectTests {

    private func failure(_ string: String) -> AuthLinkFailure? {
        let url = URL(string: string)!
        return AuthLinkFailure.redirectFailure(link: AuthDeepLink(url: url)!, url: url)
    }

    @Test func otpExpiredInQuery() {
        #expect(failure("nudge://reset-password?error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired") == .expired)
        #expect(failure("nudge://auth-callback?error=access_denied&error_code=otp_expired") == .expired)
    }

    @Test func otpExpiredInFragment() {
        #expect(failure("nudge://reset-password#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired&sb=") == .expired)
        #expect(failure("nudge://auth-callback#error_code=otp_expired") == .expired)
    }

    @Test func otpExpiredInQueryAndFragment() {
        // GoTrue's PKCE error redirect writes the params to both.
        #expect(failure("nudge://reset-password?error=access_denied&error_code=otp_expired#error=access_denied&error_code=otp_expired&sb=") == .expired)
    }

    @Test func percentEncodedErrorCodeIsDecoded() {
        #expect(failure("nudge://reset-password?error_code=flow%5Fstate%5Fnot%5Ffound") == .alreadyUsed)
        #expect(failure("nudge://reset-password#error_code=flow%5Fstate%5Fnot%5Ffound") == .alreadyUsed)
    }

    @Test func knownCodesInRedirectMapLikeServerCodes() {
        #expect(failure("nudge://reset-password?error_code=flow_state_expired") == .expired)
        #expect(failure("nudge://reset-password?error_code=flow_state_not_found") == .alreadyUsed)
        #expect(failure("nudge://reset-password?error_code=bad_code_verifier") == .olderRequest)
    }

    @Test func errorWithoutCodeFallsBack() {
        #expect(failure("nudge://reset-password?error=server_error") == .expired)
        #expect(failure("nudge://auth-callback#error_description=Something+went+wrong") == .expired)
    }

    @Test func unknownErrorCodeFallsBack() {
        #expect(failure("nudge://reset-password?error_code=something_new") == .expired)
        // validation_failed only means "no verifier" for the code exchange, not in a redirect.
        #expect(failure("nudge://reset-password?error_code=validation_failed") == .expired)
    }

    @Test func errorWinsOverCode() {
        #expect(failure("nudge://reset-password?code=abc&error_code=otp_expired") == .expired)
    }

    @Test func codeInQueryIsNotAFailure() {
        #expect(failure("nudge://reset-password?code=abc123") == nil)
        #expect(failure("nudge://auth-callback?code=abc123") == nil)
    }

    @Test func codeInFragmentIsNotAFailure() {
        // The SDK reads params from the fragment too.
        #expect(failure("nudge://reset-password#code=abc123") == nil)
    }

    @Test func noCodeAndNoErrorIsMalformed() {
        #expect(failure("nudge://reset-password") == .malformed)
        #expect(failure("nudge://auth-callback") == .malformed)
        #expect(failure("nudge://reset-password?code=") == .malformed)
        #expect(failure("nudge://auth-callback?foo=bar") == .malformed)
    }

    @Test func implicitConfirmationLinkNeedsSignIn() {
        // Defensive: an implicit-flow confirmation link (tokens in the fragment, no PKCE code).
        // /verify has confirmed the email; the app ignores the tokens and asks for sign-in.
        #expect(failure("nudge://auth-callback#access_token=x&refresh_token=y&expires_in=3600&token_type=bearer&type=signup") == .signInRequired)
    }

    @Test func implicitRecoveryLinkIsMalformed() {
        #expect(failure("nudge://reset-password#access_token=x&refresh_token=y&type=recovery") == .malformed)
    }
}

// MARK: - Link failure: exchange error classification (spec C2)

@Suite("AuthLinkFailure exchange errors")
@MainActor
struct AuthLinkFailureExchangeTests {

    @Test func transportErrorIsOffline() {
        #expect(AuthLinkFailure.exchangeFailure(from: URLError(.notConnectedToInternet)) == .offline)
        #expect(AuthLinkFailure.exchangeFailure(from: URLError(.timedOut)) == .offline)
    }

    @Test func missingVerifierIsDifferentDevice() {
        // No stored verifier: the SDK sends code_verifier null; GoTrue answers validation_failed.
        #expect(AuthLinkFailure.exchangeFailure(from: authAPIError(code: .validationFailed, status: 400)) == .differentDevice)
    }

    @Test func badCodeVerifierIsOlderRequest() {
        #expect(AuthLinkFailure.exchangeFailure(from: authAPIError(code: .badCodeVerifier, status: 400)) == .olderRequest)
    }

    @Test func flowStateNotFoundIsAlreadyUsed() {
        #expect(AuthLinkFailure.exchangeFailure(from: authAPIError(code: .flowStateNotFound, status: 404)) == .alreadyUsed)
    }

    @Test func flowStateExpiredIsExpired() {
        #expect(AuthLinkFailure.exchangeFailure(from: authAPIError(code: .flowStateExpired, status: 422)) == .expired)
    }

    @Test func otpExpiredIsExpired() {
        #expect(AuthLinkFailure.exchangeFailure(from: authAPIError(code: .otpExpired, status: 403)) == .expired)
    }

    @Test func otherServerCodesFallBack() {
        #expect(AuthLinkFailure.exchangeFailure(from: authAPIError(code: .unexpectedFailure, status: 500)) == .expired)
        #expect(AuthLinkFailure.exchangeFailure(from: authAPIError(code: .unknown, status: 400)) == .expired)
    }

    @Test func sdkParsedRedirectErrorUsesItsCode() {
        let error = Auth.AuthError.pkceGrantCodeExchange(message: "x", error: "access_denied", code: "otp_expired")
        #expect(AuthLinkFailure.exchangeFailure(from: error) == .expired)
        let used = Auth.AuthError.pkceGrantCodeExchange(message: "x", error: "e", code: "flow_state_not_found")
        #expect(AuthLinkFailure.exchangeFailure(from: used) == .alreadyUsed)
    }

    @Test func sdkNoCodeErrorIsMalformed() {
        let error = Auth.AuthError.pkceGrantCodeExchange(message: "No code detected.")
        #expect(AuthLinkFailure.exchangeFailure(from: error) == .malformed)
    }

    @Test func anythingElseFallsBack() {
        #expect(AuthLinkFailure.exchangeFailure(from: Auth.AuthError.sessionMissing) == .expired)
        #expect(AuthLinkFailure.exchangeFailure(from: NSError(domain: "x", code: 1)) == .expired)
    }
}

// MARK: - Link failure: messages (spec C2)

@Suite("AuthLinkFailure messages")
@MainActor
struct AuthLinkFailureMessageTests {

    @Test func messageWording() {
        #expect(AuthLinkFailure.expiredMessage == "This link has expired. Request a new one.")
        #expect(AuthLinkFailure.differentDeviceResetMessage == "This link was requested on a different device. Open it on the iPhone where you asked for it, or request a new one here.")
        #expect(AuthLinkFailure.confirmedSignInMessage == "Your email is confirmed. Sign in with your email and password.")
        #expect(AuthLinkFailure.olderRequestMessage == "This link is from an older request. Use the newest email, or request a new one.")
        #expect(AuthLinkFailure.alreadyUsedMessage == "This link has already been used. Request a new one if you still need it.")
        #expect(AuthLinkFailure.malformedMessage == "This link isn't valid. Request a new one.")
        #expect(AuthLinkFailure.offlineMessage == "Couldn't check the link. Check your connection and try again.")
    }

    @Test func recoveryLinkMessages() {
        let link = AuthDeepLink.passwordRecovery
        #expect(AuthLinkFailure.expired.message(for: link) == AuthLinkFailure.expiredMessage)
        #expect(AuthLinkFailure.differentDevice.message(for: link) == AuthLinkFailure.differentDeviceResetMessage)
        #expect(AuthLinkFailure.olderRequest.message(for: link) == AuthLinkFailure.olderRequestMessage)
        #expect(AuthLinkFailure.alreadyUsed.message(for: link) == AuthLinkFailure.alreadyUsedMessage)
        #expect(AuthLinkFailure.malformed.message(for: link) == AuthLinkFailure.malformedMessage)
        #expect(AuthLinkFailure.offline.message(for: link) == AuthLinkFailure.offlineMessage)
        #expect(AuthLinkFailure.signInRequired.message(for: link) == AuthLinkFailure.malformedMessage)
    }

    @Test func confirmationLinkMessages() {
        let link = AuthDeepLink.emailConfirmation
        #expect(AuthLinkFailure.expired.message(for: link) == AuthLinkFailure.expiredMessage)
        #expect(AuthLinkFailure.differentDevice.message(for: link) == AuthLinkFailure.confirmedSignInMessage)
        #expect(AuthLinkFailure.olderRequest.message(for: link) == AuthLinkFailure.olderRequestMessage)
        #expect(AuthLinkFailure.alreadyUsed.message(for: link) == AuthLinkFailure.alreadyUsedMessage)
        #expect(AuthLinkFailure.malformed.message(for: link) == AuthLinkFailure.malformedMessage)
        #expect(AuthLinkFailure.offline.message(for: link) == AuthLinkFailure.offlineMessage)
        #expect(AuthLinkFailure.signInRequired.message(for: link) == AuthLinkFailure.confirmedSignInMessage)
    }
}

// MARK: - Set new password: weak password from the server (spec C1)

@Suite("SetNewPasswordViewModel weak password")
@MainActor
struct SetNewPasswordWeakPasswordTests {

    @Test func serverReasonsAreShown() async {
        let mock = MockAuthRecoveryService()
        mock.updateError = Auth.AuthError.weakPassword(
            message: "Password is known to be weak and easy to guess, please choose a different one.",
            reasons: ["pwned"]
        )
        let vm = SetNewPasswordViewModel(service: mock)
        vm.newPassword = "password1"
        vm.confirmPassword = "password1"

        await vm.save()

        #expect(vm.errorMessage == "Password is known to be weak and easy to guess, please choose a different one.")
        #expect(vm.didSucceed == false)
    }

    @Test func noReasonsFallsBackToLengthMessage() async {
        let mock = MockAuthRecoveryService()
        mock.updateError = Auth.AuthError.weakPassword(message: "Unknown", reasons: [])
        let vm = SetNewPasswordViewModel(service: mock)
        vm.newPassword = "password1"
        vm.confirmPassword = "password1"

        await vm.save()

        #expect(vm.errorMessage == PasswordRules.tooShortMessage)
    }
}

// MARK: - Fixtures

/// A Supabase Auth API error as the SDK throws it for a GoTrue error response.
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

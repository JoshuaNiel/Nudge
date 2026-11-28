import Testing
import Foundation
import Combine
import AuthenticationServices
import Supabase
@testable import Nudge

// Confirm-email screen, Resend countdown, "this device" copy and the generic busy
// message (docs/specs/auth-recovery.md, section C5). Nothing here touches a server
// or sleeps: the countdown runs on a manual clock.

// MARK: - Which variant appears (C5)

@Suite("Confirm-email variant routing")
@MainActor
struct ConfirmEmailVariantRoutingTests {

    @Test func signUpPendingConfirmationShowsAfterSignUpVariant() async {
        let mock = MockEmailService()
        mock.signUpNeedsConfirmation = true
        let vm = AuthViewModel(service: mock)
        vm.mode = .signUp
        vm.email = "grace@example.com"
        vm.password = "12345678"
        vm.confirmPassword = "12345678"

        let outcome = await vm.submit()

        #expect(outcome == .needsEmailConfirmation(
            PendingEmailConfirmation(email: "grace@example.com", password: "12345678", variant: .afterSignUp)
        ))
        #expect(vm.errorMessage == nil)
    }

    @Test func unconfirmedSignInShowsSecondVariant() async {
        let mock = MockEmailService()
        mock.signInError = authAPIError(code: .emailNotConfirmed, status: 400)
        let vm = AuthViewModel(service: mock)
        vm.email = "grace@example.com"
        vm.password = "whatever"

        let outcome = await vm.submit()

        #expect(outcome == .needsEmailConfirmation(
            PendingEmailConfirmation(email: "grace@example.com", password: "whatever", variant: .unconfirmedSignIn)
        ))
        // The screen replaces the old inline message.
        #expect(vm.errorMessage == nil)
    }

    @Test func otherSignInErrorStaysOnForm() async {
        let mock = MockEmailService()
        mock.signInError = authAPIError(code: .invalidCredentials, status: 400)
        let vm = AuthViewModel(service: mock)
        vm.email = "grace@example.com"
        vm.password = "wrong"

        let outcome = await vm.submit()

        #expect(outcome == .failed)
        #expect(vm.errorMessage == "error")
    }

    @Test func signUpWithSessionSignsIn() async {
        let mock = MockEmailService()
        let vm = AuthViewModel(service: mock)
        vm.mode = .signUp
        vm.email = "grace@example.com"
        vm.password = "12345678"
        vm.confirmPassword = "12345678"

        #expect(await vm.submit() == .signedIn)
    }

    @Test func variantCopy() {
        #expect(ConfirmEmailVariant.afterSignUp.title == "You're almost set!")
        #expect(ConfirmEmailVariant.afterSignUp.body(email: "grace@example.com")
                == "We sent a confirmation link to grace@example.com. Open it on this device to finish setting up your account.")
        #expect(ConfirmEmailVariant.unconfirmedSignIn.title == "Confirm your email to continue")
        #expect(ConfirmEmailVariant.unconfirmedSignIn.body(email: "grace@example.com")
                == "We found your account, but your email isn't confirmed yet. Open the link we sent to grace@example.com on this device.")
    }

    @Test func pendingConfirmationNeverPrintsPassword() {
        let pending = PendingEmailConfirmation(email: "grace@example.com", password: "s3cret-pass", variant: .afterSignUp)
        #expect(!String(describing: pending).contains("s3cret-pass"))
        #expect(!String(reflecting: pending).contains("s3cret-pass"))
    }

    @Test func backToSignInPrefillsEmailInSignInMode() {
        let vm = AuthViewModel(service: MockEmailService(), prefillEmail: "grace@example.com")

        #expect(vm.email == "grace@example.com")
        #expect(vm.mode == .signIn)
        #expect(vm.password.isEmpty)
    }
}

// MARK: - Countdown + Resend (C5)

@Suite("ConfirmEmailViewModel countdown and resend")
@MainActor
struct ConfirmEmailViewModelTests {

    private let pending = PendingEmailConfirmation(
        email: "grace@example.com", password: "whatever", variant: .unconfirmedSignIn
    )

    private func model(_ mock: MockEmailService = MockEmailService(), clock: ManualCountdownClock = ManualCountdownClock()) -> ConfirmEmailViewModel {
        // A repeat sign-up of an unconfirmed address returns no session.
        mock.signUpNeedsConfirmation = true
        return ConfirmEmailViewModel(pending: pending, service: mock, clock: clock)
    }

    @Test func exposesVariantAndEmail() {
        let vm = model()
        #expect(vm.variant == .unconfirmedSignIn)
        #expect(vm.email == "grace@example.com")
    }

    @Test func countdownStartsAtThirtyOnAppear() {
        let clock = ManualCountdownClock()
        let vm = model(clock: clock)

        vm.onAppear()

        #expect(vm.secondsRemaining == 30)
        #expect(vm.canResend == false)
        #expect(vm.resendButtonTitle == "Resend in 0:30")
        #expect(clock.activeTickers == 1)
    }

    @Test func countdownTicks() {
        let clock = ManualCountdownClock()
        let vm = model(clock: clock)
        vm.onAppear()

        clock.advance(by: 1)
        #expect(vm.secondsRemaining == 29)
        #expect(vm.resendButtonTitle == "Resend in 0:29")

        clock.advance(by: 19)
        #expect(vm.secondsRemaining == 10)
        #expect(vm.resendButtonTitle == "Resend in 0:10")

        clock.advance(by: 1)
        #expect(vm.resendButtonTitle == "Resend in 0:09")
        #expect(vm.canResend == false)
    }

    @Test func countdownUsesElapsedTimeNotTickCount() {
        // A backgrounded app skips ticks; the next tick still shows the true remaining time.
        let clock = ManualCountdownClock()
        let vm = model(clock: clock)
        vm.onAppear()

        clock.advance(by: 12, ticks: false)
        clock.tick()

        #expect(vm.secondsRemaining == 18)
    }

    @Test func enablesAtZeroAndStopsTicking() {
        let clock = ManualCountdownClock()
        let vm = model(clock: clock)
        vm.onAppear()

        clock.advance(by: 30)

        #expect(vm.secondsRemaining == 0)
        #expect(vm.canResend)
        #expect(vm.resendButtonTitle == "Resend email")
        #expect(clock.activeTickers == 0)
    }

    @Test func neverGoesNegative() {
        let clock = ManualCountdownClock()
        let vm = model(clock: clock)
        vm.onAppear()

        clock.advance(by: 45, ticks: false)
        clock.tick()

        #expect(vm.secondsRemaining == 0)
    }

    @Test func appearingAgainDoesNotRestart() {
        let clock = ManualCountdownClock()
        let vm = model(clock: clock)
        vm.onAppear()
        clock.advance(by: 10)

        vm.onAppear()

        #expect(vm.secondsRemaining == 20)
        #expect(clock.activeTickers == 1)
    }

    @Test func resendBlockedDuringCountdown() async {
        let mock = MockEmailService()
        let clock = ManualCountdownClock()
        let vm = model(mock, clock: clock)
        vm.onAppear()
        clock.advance(by: 29)

        let signedIn = await vm.resend()

        #expect(signedIn == false)
        #expect(mock.signUps.isEmpty)
    }

    @Test func resendUsesCapturedCredentials() async {
        let mock = MockEmailService()
        let clock = ManualCountdownClock()
        let vm = model(mock, clock: clock)
        vm.onAppear()
        clock.advance(by: 30)

        let signedIn = await vm.resend()

        #expect(signedIn == false)
        #expect(mock.signUps == [.init(email: "grace@example.com", password: "whatever")])
        #expect(mock.signIns.isEmpty)
    }

    @Test func successShowsSentMessageAndRestartsCountdown() async {
        let mock = MockEmailService()
        let clock = ManualCountdownClock()
        let vm = model(mock, clock: clock)
        vm.onAppear()
        clock.advance(by: 30)

        await vm.resend()

        #expect(vm.resendStatus == .sent)
        #expect(vm.resendMessage == "Email sent. Check your inbox for the new link.")
        #expect(vm.secondsRemaining == 30)
        #expect(vm.canResend == false)
        #expect(vm.resendButtonTitle == "Resend in 0:30")
        #expect(clock.activeTickers == 1)
    }

    @Test func rateLimitShowsBusyMessageAndRestartsCountdown() async {
        let mock = MockEmailService()
        let clock = ManualCountdownClock()
        let vm = model(mock, clock: clock)
        vm.onAppear()
        clock.advance(by: 30)
        mock.signUpError = authAPIError(code: .overEmailSendRateLimit, status: 429)

        let signedIn = await vm.resend()

        #expect(signedIn == false)
        #expect(vm.resendStatus == .failed(AuthErrorMapping.busyMessage))
        #expect(vm.resendMessage == "Our servers are busy right now. Please try again in a moment.")
        #expect(vm.secondsRemaining == 30)
        #expect(vm.canResend == false)
    }

    @Test func http429WithoutCodeIsRateLimit() async {
        let mock = MockEmailService()
        let clock = ManualCountdownClock()
        let vm = model(mock, clock: clock)
        vm.onAppear()
        clock.advance(by: 30)
        mock.signUpError = authAPIError(code: .unknown, status: 429)

        await vm.resend()

        #expect(vm.resendMessage == AuthErrorMapping.busyMessage)
        #expect(vm.secondsRemaining == 30)
    }

    @Test func otherFailureShowsGenericMessageAndAllowsRetry() async {
        let mock = MockEmailService()
        let clock = ManualCountdownClock()
        let vm = model(mock, clock: clock)
        vm.onAppear()
        clock.advance(by: 30)
        mock.signUpError = URLError(.notConnectedToInternet)

        let signedIn = await vm.resend()

        #expect(signedIn == false)
        #expect(vm.resendStatus == .failed("Couldn't send the email. Try again."))
        #expect(vm.canResend)

        mock.signUpError = nil
        await vm.resend()
        #expect(mock.signUps.count == 2)
        #expect(vm.resendStatus == .sent)
    }

    @Test func canResendAgainAfterEachCountdown() async {
        let mock = MockEmailService()
        let clock = ManualCountdownClock()
        let vm = model(mock, clock: clock)
        vm.onAppear()

        for _ in 0..<3 {
            clock.advance(by: 30)
            #expect(vm.canResend)
            await vm.resend()
        }

        #expect(mock.signUps.count == 3)
        #expect(mock.signUps.allSatisfy { $0 == .init(email: "grace@example.com", password: "whatever") })
    }

    @Test func sessionReturnedSignsIn() async {
        // Confirmed in the meantime: signUp returns a session, so it's a normal sign-in.
        let mock = MockEmailService()
        let clock = ManualCountdownClock()
        let vm = model(mock, clock: clock)
        vm.onAppear()
        clock.advance(by: 30)
        mock.signUpNeedsConfirmation = false

        let signedIn = await vm.resend()

        #expect(signedIn)
        #expect(vm.canResend == false)
        #expect(clock.activeTickers == 0)
    }

    @Test func leavingClearsPasswordAndStopsCountdown() async {
        let mock = MockEmailService()
        let clock = ManualCountdownClock()
        let vm = model(mock, clock: clock)
        vm.onAppear()
        clock.advance(by: 30)

        vm.leave()

        #expect(vm.canResend == false)
        #expect(clock.activeTickers == 0)
        let signedIn = await vm.resend()
        #expect(signedIn == false)
        #expect(mock.signUps.isEmpty)
    }

    @Test func backToSignInClearsPasswordAndReturnsEmail() async {
        let mock = MockEmailService()
        let clock = ManualCountdownClock()
        let vm = model(mock, clock: clock)
        vm.onAppear()
        clock.advance(by: 30)

        let email = vm.backToSignIn()

        #expect(email == "grace@example.com")
        #expect(vm.canResend == false)
        await vm.resend()
        #expect(mock.signUps.isEmpty)
    }
}

// MARK: - Generic 429 in every auth flow (C5)

@Suite("Generic busy message for rate limits")
@MainActor
struct AuthBusyMessageTests {

    @Test func wording() {
        #expect(AuthErrorMapping.busyMessage == "Our servers are busy right now. Please try again in a moment.")
        #expect(AuthError.rateLimited.localizedDescription == AuthErrorMapping.busyMessage)
    }

    @Test(arguments: [
        RateLimitCase.emailSend, .request, .httpStatusOnly, .appError,
    ])
    func signInRateLimit(_ rateLimit: RateLimitCase) async {
        let mock = MockEmailService()
        mock.signInError = rateLimit.error
        let vm = AuthViewModel(service: mock)
        vm.email = "grace@example.com"
        vm.password = "whatever"

        let outcome = await vm.submit()

        #expect(outcome == .failed)
        #expect(vm.errorMessage == AuthErrorMapping.busyMessage)
    }

    @Test(arguments: [
        RateLimitCase.emailSend, .request, .httpStatusOnly, .appError,
    ])
    func signUpRateLimit(_ rateLimit: RateLimitCase) async {
        let mock = MockEmailService()
        mock.signUpError = rateLimit.error
        let vm = AuthViewModel(service: mock)
        vm.mode = .signUp
        vm.email = "grace@example.com"
        vm.password = "12345678"
        vm.confirmPassword = "12345678"

        let outcome = await vm.submit()

        #expect(outcome == .failed)
        #expect(vm.errorMessage == AuthErrorMapping.busyMessage)
    }

    @Test func resetRequestRateLimit() async {
        let mock = MockRecoveryService()
        mock.resetError = AuthError.rateLimited
        let vm = ForgotPasswordViewModel(email: "grace@example.com", service: mock)

        await vm.submit()

        #expect(vm.status == .rateLimited)
        #expect(vm.statusMessage == AuthErrorMapping.busyMessage)
    }

    @Test(arguments: [
        RateLimitCase.emailSend, .request, .httpStatusOnly, .appError,
    ])
    func setNewPasswordRateLimit(_ rateLimit: RateLimitCase) async {
        let mock = MockRecoveryService()
        mock.updateError = rateLimit.error
        let vm = SetNewPasswordViewModel(service: mock)
        vm.newPassword = "12345678"
        vm.confirmPassword = "12345678"

        await vm.save()

        #expect(vm.didSucceed == false)
        #expect(vm.errorMessage == AuthErrorMapping.busyMessage)
    }

    @Test func rateLimitMessageHelper() {
        #expect(AuthErrorMapping.rateLimitMessage(for: authAPIError(code: .overRequestRateLimit, status: 429)) == AuthErrorMapping.busyMessage)
        #expect(AuthErrorMapping.rateLimitMessage(for: authAPIError(code: .invalidCredentials, status: 400)) == nil)
        #expect(AuthErrorMapping.rateLimitMessage(for: URLError(.timedOut)) == nil)
    }
}

// MARK: - "This device" wording (C5)

@Suite("Auth copy says 'this device'")
@MainActor
struct AuthDeviceWordingTests {

    @Test func differentDeviceMessage() {
        #expect(AuthLinkFailure.differentDeviceResetMessage
                == "This link was requested on a different device. Open it on the device where you asked for it, or request a new one here.")
    }

    @Test func forgotPasswordInstructions() {
        #expect(ForgotPasswordViewModel.instructionsMessage
                == "Enter the email you use for Nudge and we'll send you a link to choose a new password. Open the link on this device.")
    }

    @Test func noIPhoneInAuthCopy() {
        var copy: [String] = [
            ForgotPasswordViewModel.instructionsMessage,
            ForgotPasswordViewModel.neutralMessage,
            ForgotPasswordViewModel.offlineMessage,
            ForgotPasswordViewModel.invalidEmailMessage,
            AuthErrorMapping.busyMessage,
            AuthViewModel.missingFieldsMessage,
            ConfirmEmailViewModel.resendSentMessage,
            ConfirmEmailViewModel.resendFailedMessage,
            AuthLinkFailure.alertTitle,
        ]
        for failure in AuthLinkFailure.allCases {
            copy.append(failure.message(for: .passwordRecovery))
            copy.append(failure.message(for: .emailConfirmation))
        }
        for variant in [ConfirmEmailVariant.afterSignUp, .unconfirmedSignIn] {
            copy.append(variant.title)
            copy.append(variant.body(email: "grace@example.com"))
        }

        for line in copy {
            #expect(!line.localizedCaseInsensitiveContains("iphone"), "\(line)")
        }
    }
}

// MARK: - Fixtures

enum RateLimitCase: CustomTestStringConvertible, Sendable {
    case emailSend, request, httpStatusOnly, appError

    var error: Error {
        switch self {
        case .emailSend: authAPIError(code: .overEmailSendRateLimit, status: 429)
        case .request: authAPIError(code: .overRequestRateLimit, status: 400)
        case .httpStatusOnly: authAPIError(code: .unknown, status: 429)
        case .appError: AuthError.rateLimited
        }
    }

    var testDescription: String {
        switch self {
        case .emailSend: "over_email_send_rate_limit"
        case .request: "over_request_rate_limit"
        case .httpStatusOnly: "HTTP 429"
        case .appError: "AuthError.rateLimited"
        }
    }
}

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

/// Test clock: time moves only when the test says so, and ticks fire synchronously.
private final class ManualCountdownClock: CountdownClock {
    private(set) var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var handlers: [UUID: () -> Void] = [:]

    var activeTickers: Int { handlers.count }

    func ticks(_ onTick: @escaping () -> Void) -> AnyCancellable {
        let id = UUID()
        handlers[id] = onTick
        return AnyCancellable { [weak self] in self?.handlers[id] = nil }
    }

    /// Moves time forward one second at a time, ticking after each (like the real
    /// 1 s timer), or in a single jump with no ticks (a backgrounded app).
    func advance(by seconds: Int, ticks: Bool = true) {
        guard ticks else {
            now += TimeInterval(seconds)
            return
        }
        for _ in 0..<seconds {
            now += 1
            tick()
        }
    }

    func tick() {
        for handler in Array(handlers.values) { handler() }
    }
}

private final class MockEmailService: AuthEmailServiceProtocol {
    struct Credentials: Equatable {
        let email: String
        let password: String
    }

    var signInError: Error?
    var signUpError: Error?
    var signUpNeedsConfirmation = false

    var signIns: [Credentials] = []
    var signUps: [Credentials] = []

    func signIn(email: String, password: String) async throws {
        signIns.append(.init(email: email, password: password))
        if let signInError { throw signInError }
    }

    func signUp(email: String, password: String) async throws -> Bool {
        signUps.append(.init(email: email, password: password))
        if let signUpError { throw signUpError }
        return signUpNeedsConfirmation
    }

    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async throws {}
}

private final class MockRecoveryService: AuthRecoveryServiceProtocol {
    var resetError: Error?
    var updateError: Error?

    func sendPasswordReset(email: String) async throws {
        if let resetError { throw resetError }
    }

    func establishSession(from url: URL) async throws {}

    func updatePassword(_ newPassword: String) async throws {
        if let updateError { throw updateError }
    }
}

import Testing
import Foundation
import AuthenticationServices
import Supabase
@testable import Nudge

// Email/password sign-in and sign-up (docs/specs/auth-recovery.md, section C).
// C1: sign-up uses PasswordRules and maps the server's weak_password.
// C3: sign-in before confirming shows a message plus a Resend action.
// The SDK calls are behind AuthEmailServiceProtocol; nothing here touches a server.

// MARK: - Sign-up validation (C1)

@Suite("AuthViewModel sign-up validation")
@MainActor
struct AuthViewModelSignUpValidationTests {

    private func signUpModel(_ mock: MockAuthEmailService, password: String, confirmation: String) -> AuthViewModel {
        let vm = AuthViewModel(service: mock)
        vm.mode = .signUp
        vm.email = "grace@example.com"
        vm.password = password
        vm.confirmPassword = confirmation
        return vm
    }

    @Test func sevenCharactersRejected() async {
        let mock = MockAuthEmailService()
        let vm = signUpModel(mock, password: "1234567", confirmation: "1234567")

        let signedIn = await vm.submit()

        #expect(signedIn == false)
        #expect(mock.signUps.isEmpty)
        #expect(vm.errorMessage == PasswordRules.tooShortMessage)
    }

    @Test func eightCharactersAccepted() async {
        let mock = MockAuthEmailService()
        let vm = signUpModel(mock, password: "12345678", confirmation: "12345678")

        let signedIn = await vm.submit()

        #expect(signedIn)
        #expect(mock.signUps == [.init(email: "grace@example.com", password: "12345678")])
        #expect(vm.errorMessage == nil)
        #expect(vm.isLoading == false)
    }

    @Test func mismatchRejected() async {
        let mock = MockAuthEmailService()
        let vm = signUpModel(mock, password: "longenough1", confirmation: "longenough2")

        _ = await vm.submit()

        #expect(mock.signUps.isEmpty)
        #expect(vm.errorMessage == PasswordRules.mismatchMessage)
    }

    @Test func lengthCheckedBeforeMatch() async {
        let mock = MockAuthEmailService()
        let vm = signUpModel(mock, password: "short", confirmation: "other")

        _ = await vm.submit()

        #expect(vm.errorMessage == PasswordRules.tooShortMessage)
    }

    @Test func passwordIsNotTrimmed() async {
        let mock = MockAuthEmailService()
        // 7 visible characters + 1 space = 8: accepted, and sent with the space.
        let vm = signUpModel(mock, password: "abcdefg ", confirmation: "abcdefg ")

        _ = await vm.submit()

        #expect(mock.signUps == [.init(email: "grace@example.com", password: "abcdefg ")])
    }

    @Test func surroundingWhitespaceCountsTowardLength() async {
        let mock = MockAuthEmailService()
        // Trimming would make this 6; untrimmed it is 8 and passes. The rule counts every character.
        let vm = signUpModel(mock, password: " abcdef ", confirmation: " abcdef ")

        _ = await vm.submit()

        #expect(vm.errorMessage == nil)
        #expect(mock.signUps.map(\.password) == [" abcdef "])
    }

    @Test func emptyFieldsAskToFillIn() async {
        let mock = MockAuthEmailService()
        let vm = signUpModel(mock, password: "", confirmation: "")

        _ = await vm.submit()

        #expect(vm.errorMessage == AuthViewModel.missingFieldsMessage)
        #expect(mock.signUps.isEmpty)
    }

    @Test func pendingConfirmationShowsCheckEmail() async {
        let mock = MockAuthEmailService()
        mock.signUpNeedsConfirmation = true
        let vm = signUpModel(mock, password: "12345678", confirmation: "12345678")

        let signedIn = await vm.submit()

        #expect(signedIn == false)
        #expect(vm.confirmationSentTo == "grace@example.com")
    }

    @Test func passwordHintWording() {
        #expect(AuthViewModel.passwordHint == "Use at least 8 characters.")
    }

    @Test func signInHasNoLengthCheck() async {
        // Existing accounts may have passwords shorter than 8.
        let mock = MockAuthEmailService()
        let vm = AuthViewModel(service: mock)
        vm.email = "grace@example.com"
        vm.password = "short"

        let signedIn = await vm.submit()

        #expect(signedIn)
        #expect(mock.signIns == [.init(email: "grace@example.com", password: "short")])
    }
}

// MARK: - Weak password from the server (C1)

@Suite("AuthViewModel weak password")
@MainActor
struct AuthViewModelWeakPasswordTests {

    private func signUpModel(_ mock: MockAuthEmailService) -> AuthViewModel {
        let vm = AuthViewModel(service: mock)
        vm.mode = .signUp
        vm.email = "grace@example.com"
        vm.password = "password1"
        vm.confirmPassword = "password1"
        return vm
    }

    @Test func serverReasonsAreShown() async {
        let mock = MockAuthEmailService()
        mock.signUpError = Auth.AuthError.weakPassword(
            message: "Password should contain at least one character of each: abc, 123.",
            reasons: ["characters"]
        )
        let vm = signUpModel(mock)

        _ = await vm.submit()

        #expect(vm.errorMessage == "Password should contain at least one character of each: abc, 123.")
    }

    @Test func noReasonsFallsBackToLengthMessage() async {
        let mock = MockAuthEmailService()
        mock.signUpError = Auth.AuthError.weakPassword(message: "", reasons: [])
        let vm = signUpModel(mock)

        _ = await vm.submit()

        #expect(vm.errorMessage == PasswordRules.tooShortMessage)
    }

    @Test func mappingHelper() {
        let withReasons = Auth.AuthError.weakPassword(message: "Password should be at least 10 characters.", reasons: ["length"])
        #expect(AuthErrorMapping.weakPasswordMessage(for: withReasons) == "Password should be at least 10 characters.")
        #expect(AuthErrorMapping.weakPasswordMessage(for: Auth.AuthError.weakPassword(message: "Unknown", reasons: [])) == PasswordRules.tooShortMessage)
        #expect(AuthErrorMapping.weakPasswordMessage(for: authAPIError(code: .validationFailed, status: 400)) == nil)
        #expect(AuthErrorMapping.weakPasswordMessage(for: URLError(.timedOut)) == nil)
    }
}

// MARK: - Email not confirmed + Resend (C3)

@Suite("AuthViewModel email not confirmed")
@MainActor
struct AuthViewModelEmailNotConfirmedTests {

    private func unconfirmedModel(_ mock: MockAuthEmailService) async -> AuthViewModel {
        mock.signInError = authAPIError(code: .emailNotConfirmed, status: 400)
        let vm = AuthViewModel(service: mock)
        vm.email = "grace@example.com"
        vm.password = "whatever"
        _ = await vm.submit()
        return vm
    }

    @Test func messageWording() {
        #expect(AuthViewModel.emailNotConfirmedMessage == "Confirm your email first. Check your inbox for the link.")
    }

    @Test func emailNotConfirmedShowsMessageAndResend() async {
        let vm = await unconfirmedModel(MockAuthEmailService())

        #expect(vm.errorMessage == AuthViewModel.emailNotConfirmedMessage)
        #expect(vm.unconfirmedEmail == "grace@example.com")
        #expect(vm.canResendConfirmation)
    }

    @Test func otherSignInErrorHasNoResend() async {
        let mock = MockAuthEmailService()
        mock.signInError = authAPIError(code: .invalidCredentials, status: 400)
        let vm = AuthViewModel(service: mock)
        vm.email = "grace@example.com"
        vm.password = "wrong"

        _ = await vm.submit()

        #expect(vm.errorMessage == "error")
        #expect(vm.unconfirmedEmail == nil)
        #expect(vm.canResendConfirmation == false)
    }

    @Test func resendSendsToTheUnconfirmedEmail() async {
        let mock = MockAuthEmailService()
        let vm = await unconfirmedModel(mock)
        // Editing the field afterwards doesn't change where the email goes.
        vm.email = "other@example.com"

        await vm.resendConfirmation()

        #expect(mock.resentEmails == ["grace@example.com"])
        #expect(vm.resendStatus == .sent)
        #expect(vm.resendMessage == AuthViewModel.resendSentMessage)
    }

    @Test func resendRateLimitShowsWaitMessage() async {
        let mock = MockAuthEmailService()
        let vm = await unconfirmedModel(mock)
        mock.resendError = authAPIError(code: .overEmailSendRateLimit, status: 429)

        await vm.resendConfirmation()

        #expect(vm.resendStatus == .failed(AuthError.rateLimited.localizedDescription))
        #expect(vm.resendMessage == "Please wait a minute before trying again.")
    }

    @Test func resendHTTP429WithoutCodeIsRateLimit() async {
        let mock = MockAuthEmailService()
        let vm = await unconfirmedModel(mock)
        mock.resendError = authAPIError(code: .unknown, status: 429)

        await vm.resendConfirmation()

        #expect(vm.resendMessage == "Please wait a minute before trying again.")
    }

    @Test func resendOtherErrorShowsItsDescription() async {
        let mock = MockAuthEmailService()
        let vm = await unconfirmedModel(mock)
        mock.resendError = URLError(.notConnectedToInternet)

        await vm.resendConfirmation()

        #expect(vm.resendStatus == .failed(URLError(.notConnectedToInternet).localizedDescription))
    }

    @Test func resendDoesNothingWithoutUnconfirmedEmail() async {
        let mock = MockAuthEmailService()
        let vm = AuthViewModel(service: mock)

        await vm.resendConfirmation()

        #expect(mock.resentEmails.isEmpty)
        #expect(vm.resendStatus == .idle)
    }

    @Test func resubmitClearsResendState() async {
        let mock = MockAuthEmailService()
        let vm = await unconfirmedModel(mock)
        await vm.resendConfirmation()
        mock.signInError = nil

        _ = await vm.submit()

        #expect(vm.unconfirmedEmail == nil)
        #expect(vm.resendStatus == .idle)
        #expect(vm.errorMessage == nil)
    }

    @Test func toggleModeClearsResendState() async {
        let vm = await unconfirmedModel(MockAuthEmailService())

        vm.toggleMode()

        #expect(vm.mode == .signUp)
        #expect(vm.unconfirmedEmail == nil)
        #expect(vm.errorMessage == nil)
        #expect(vm.password.isEmpty)
    }

    @Test func mappingHelpers() {
        #expect(AuthErrorMapping.isEmailNotConfirmed(authAPIError(code: .emailNotConfirmed, status: 400)))
        #expect(AuthErrorMapping.isEmailNotConfirmed(authAPIError(code: .invalidCredentials, status: 400)) == false)
        #expect(AuthErrorMapping.isEmailNotConfirmed(URLError(.timedOut)) == false)
        #expect(AuthErrorMapping.isRateLimited(authAPIError(code: .overEmailSendRateLimit, status: 429)))
        #expect(AuthErrorMapping.isRateLimited(authAPIError(code: .overRequestRateLimit, status: 400)))
        #expect(AuthErrorMapping.isRateLimited(AuthError.rateLimited))
        #expect(AuthErrorMapping.isRateLimited(authAPIError(code: .validationFailed, status: 400)) == false)
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

private final class MockAuthEmailService: AuthEmailServiceProtocol {
    struct Credentials: Equatable {
        let email: String
        let password: String
    }

    var signInError: Error?
    var signUpError: Error?
    var resendError: Error?
    var signUpNeedsConfirmation = false

    var signIns: [Credentials] = []
    var signUps: [Credentials] = []
    var resentEmails: [String] = []

    func signIn(email: String, password: String) async throws {
        signIns.append(.init(email: email, password: password))
        if let signInError { throw signInError }
    }

    func signUp(email: String, password: String) async throws -> Bool {
        signUps.append(.init(email: email, password: password))
        if let signUpError { throw signUpError }
        return signUpNeedsConfirmation
    }

    func resendSignupConfirmation(email: String) async throws {
        resentEmails.append(email)
        if let resendError { throw resendError }
    }

    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async throws {}
}

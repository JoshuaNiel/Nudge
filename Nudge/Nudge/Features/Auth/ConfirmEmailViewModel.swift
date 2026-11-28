import Foundation
import Combine

/// Which confirm-email screen to show (docs/specs/auth-recovery.md, C5).
enum ConfirmEmailVariant: Equatable {
    /// `signUp` returned without a session: confirmation is pending.
    case afterSignUp
    /// Sign-in was refused with `email_not_confirmed`.
    case unconfirmedSignIn

    var title: String {
        switch self {
        case .afterSignUp: "You're almost set!"
        case .unconfirmedSignIn: "Confirm your email to continue"
        }
    }

    /// Body copy before the (bold) email address.
    var bodyBeforeEmail: String {
        switch self {
        case .afterSignUp: "We sent a confirmation link to "
        case .unconfirmedSignIn: "We found your account, but your email isn't confirmed yet. Open the link we sent to "
        }
    }

    /// Body copy after the email address.
    var bodyAfterEmail: String {
        switch self {
        case .afterSignUp: ". Open it on this device to finish setting up your account."
        case .unconfirmedSignIn: " on this device."
        }
    }

    /// The full body as plain text.
    func body(email: String) -> String {
        bodyBeforeEmail + email + bodyAfterEmail
    }
}

/// The credentials and variant handed from the sign-in form to the confirm-email screen.
///
/// Holds the password so Resend can repeat the PKCE sign-up (C3). Memory only: it lives
/// in the onboarding step while the screen is shown and is dropped when the user leaves.
/// The descriptions and mirror redact it so it can't end up in a log or a debugger dump.
struct PendingEmailConfirmation: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let email: String
    let password: String
    let variant: ConfirmEmailVariant

    var description: String { "PendingEmailConfirmation(email: \(email), password: <redacted>, variant: \(variant))" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["email": email, "password": "<redacted>", "variant": variant])
    }
}

/// Drives the confirm-email screen: the Resend countdown and the Resend action.
///
/// Resend repeats `signUp` with the screen's captured credentials (PKCE link, unlike
/// `auth.resend`). The countdown starts when the screen appears and restarts after
/// every resend that reached the server's answer (sent, or rate-limited).
@MainActor
final class ConfirmEmailViewModel: ObservableObject {

    enum ResendStatus: Equatable {
        case idle
        case sending
        case sent
        case failed(String)
    }

    static let countdownSeconds = 30
    static let resendSentMessage = "Email sent. Check your inbox for the new link."
    static let resendFailedMessage = "Couldn't send the email. Try again."

    let variant: ConfirmEmailVariant
    let email: String

    @Published private(set) var secondsRemaining = ConfirmEmailViewModel.countdownSeconds
    @Published private(set) var resendStatus: ResendStatus = .idle

    /// Memory only; never logged or persisted. Cleared when the user leaves the screen
    /// or a resend turns out to be a sign-in.
    private var password: String?

    private let service: AuthEmailServiceProtocol
    private let clock: CountdownClock
    private var countdownEndsAt: Date?
    private var ticker: AnyCancellable?
    private var hasAppeared = false

    // Production init — uses the real service and clock
    convenience init(pending: PendingEmailConfirmation) {
        self.init(pending: pending, service: AuthService(), clock: SystemCountdownClock())
    }

    // Test init — accepts a mock service and a manual clock
    init(pending: PendingEmailConfirmation, service: AuthEmailServiceProtocol, clock: CountdownClock) {
        self.variant = pending.variant
        self.email = pending.email
        self.password = pending.password
        self.service = service
        self.clock = clock
    }

    // MARK: - Computed

    var canResend: Bool {
        password != nil && secondsRemaining == 0 && resendStatus != .sending
    }

    var resendButtonTitle: String {
        guard secondsRemaining > 0 else { return "Resend email" }
        return String(format: "Resend in %d:%02d", secondsRemaining / 60, secondsRemaining % 60)
    }

    var resendMessage: String? {
        switch resendStatus {
        case .idle, .sending: nil
        case .sent: Self.resendSentMessage
        case .failed(let message): message
        }
    }

    // MARK: - Lifecycle

    /// Starts the countdown the first time the screen appears.
    func onAppear() {
        guard !hasAppeared else { return }
        hasAppeared = true
        startCountdown()
    }

    /// Drops the password and stops the countdown. Call whenever the screen goes away.
    func leave() {
        password = nil
        stopCountdown()
    }

    /// Leaves the screen and returns the email to prefill on the sign-in form.
    func backToSignIn() -> String {
        leave()
        return email
    }

    // MARK: - Actions

    /// Repeats the sign-up with the captured credentials. Returns `true` when a session
    /// now exists (the email was confirmed meanwhile), which is a normal sign-in.
    @discardableResult
    func resend() async -> Bool {
        guard canResend, let password else { return false }
        resendStatus = .sending
        do {
            let confirmationPending = try await service.signUp(email: email, password: password)
            // The user left while the request was in flight: don't restart anything.
            guard self.password != nil else { return !confirmationPending }
            guard confirmationPending else {
                leave()
                resendStatus = .idle
                return true
            }
            resendStatus = .sent
            startCountdown()
        } catch {
            guard self.password != nil else { return false }
            if let busy = AuthErrorMapping.rateLimitMessage(for: error) {
                resendStatus = .failed(busy)
                startCountdown()
            } else {
                // Not throttled: let the user retry straight away.
                resendStatus = .failed(Self.resendFailedMessage)
            }
        }
        return false
    }

    // MARK: - Countdown

    private func startCountdown() {
        countdownEndsAt = clock.now.addingTimeInterval(TimeInterval(Self.countdownSeconds))
        // Skip the no-op write on first appear (already 30): it would still publish.
        if secondsRemaining != Self.countdownSeconds {
            secondsRemaining = Self.countdownSeconds
        }
        ticker = clock.ticks { [weak self] in self?.updateRemaining() }
    }

    private func updateRemaining() {
        guard let countdownEndsAt else { return }
        let remaining = countdownEndsAt.timeIntervalSince(clock.now)
        secondsRemaining = max(0, Int(remaining.rounded(.up)))
        if secondsRemaining == 0 { stopCountdown() }
    }

    private func stopCountdown() {
        ticker?.cancel()
        ticker = nil
        countdownEndsAt = nil
    }
}

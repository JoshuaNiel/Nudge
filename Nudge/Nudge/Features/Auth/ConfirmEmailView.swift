import SwiftUI

/// Full-screen "check your email" step of the signed-out flow (auth-recovery spec C5).
///
/// Shown after a sign-up that awaits confirmation, or a sign-in refused because the email
/// isn't confirmed. Tapping the emailed link signs in; `OnboardingCoordinator` then moves
/// past this step on its own, so the view has no "I've confirmed" button.
struct ConfirmEmailView: View {
    /// A resend found the email already confirmed and signed in.
    var onAuthenticated: () -> Void
    /// Returns to the sign-in form, prefilled with this email.
    var onBackToSignIn: (String) -> Void

    @StateObject private var viewModel: ConfirmEmailViewModel

    init(
        pending: PendingEmailConfirmation,
        onAuthenticated: @escaping () -> Void,
        onBackToSignIn: @escaping (String) -> Void
    ) {
        self.onAuthenticated = onAuthenticated
        self.onBackToSignIn = onBackToSignIn
        _viewModel = StateObject(wrappedValue: ConfirmEmailViewModel(pending: pending))
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                Text(viewModel.variant.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                Text(bodyText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 12) {
                resendButton

                if let resendMessage = viewModel.resendMessage {
                    Text(resendMessage)
                        .font(.footnote)
                        .foregroundStyle(viewModel.resendStatus == .sent ? Color.secondary : Color.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Button("Back to Sign In", action: backToSignIn)
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 8)
            }
            .padding(.bottom, 40)
        }
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.leave() }
    }

    private var resendButton: some View {
        Button(action: resend) {
            Group {
                if viewModel.resendStatus == .sending {
                    ProgressView()
                } else {
                    Text(viewModel.resendButtonTitle)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(viewModel.canResend ? Color.accentColor : Color.secondary)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!viewModel.canResend)
        .padding(.horizontal, 24)
    }

    /// The variant's body with the email address in bold.
    private var bodyText: AttributedString {
        var emailRun = AttributedString(viewModel.email)
        emailRun.inlinePresentationIntent = .stronglyEmphasized
        return AttributedString(viewModel.variant.bodyBeforeEmail)
            + emailRun
            + AttributedString(viewModel.variant.bodyAfterEmail)
    }

    // MARK: - Previews
}

#Preview("After sign-up") {
    ConfirmEmailView(
        pending: PendingEmailConfirmation(email: "grace@example.com", password: "preview-only", variant: .afterSignUp),
        onAuthenticated: {},
        onBackToSignIn: { _ in }
    )
}

#Preview("Unconfirmed sign-in") {
    ConfirmEmailView(
        pending: PendingEmailConfirmation(email: "grace@example.com", password: "preview-only", variant: .unconfirmedSignIn),
        onAuthenticated: {},
        onBackToSignIn: { _ in }
    )
}

extension ConfirmEmailView {
    // MARK: - Actions

    private func resend() {
        Task {
            if await viewModel.resend() { onAuthenticated() }
        }
    }

    private func backToSignIn() {
        onBackToSignIn(viewModel.backToSignIn())
    }
}

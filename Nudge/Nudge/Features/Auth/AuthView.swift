import SwiftUI
import AuthenticationServices

struct AuthView: View {
    var onAuthenticated: () -> Void
    /// Opens the reset-password sheet, pre-filled with whatever email is typed.
    var onForgotPassword: (String) -> Void

    @StateObject private var viewModel = AuthViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                // Header
                VStack(spacing: 8) {
                    Text("Nudge")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text(viewModel.mode == .signIn ? "Welcome back" : "Create your account")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 48)

                // Email/password fields
                VStack(spacing: 12) {
                    TextField("Email", text: $viewModel.email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .textFieldStyle(.roundedBorder)

                    SecureField("Password", text: $viewModel.password)
                        .textContentType(viewModel.mode == .signIn ? .password : .newPassword)
                        .textFieldStyle(.roundedBorder)

                    if viewModel.mode == .signUp {
                        Text(AuthViewModel.passwordHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        SecureField("Confirm password", text: $viewModel.confirmPassword)
                            .textContentType(.newPassword)
                            .textFieldStyle(.roundedBorder)
                    }

                    if viewModel.mode == .signIn {
                        Button("Forgot password?", action: forgotPassword)
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 24)

                // Awaiting email confirmation
                if let confirmationSentTo = viewModel.confirmationSentTo {
                    Text("Check \(confirmationSentTo) for a link to confirm your account. Open it on this iPhone to continue.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Error
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Signed in before confirming the email
                if viewModel.unconfirmedEmail != nil {
                    resendConfirmationSection
                }

                // Primary action
                Button(action: submitEmailPassword) {
                    Group {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Text(viewModel.mode == .signIn ? "Sign In" : "Sign Up")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(viewModel.isLoading)
                .padding(.horizontal, 24)

                // Divider
                HStack {
                    Rectangle().frame(height: 1).foregroundStyle(.separator)
                    Text("or").font(.footnote).foregroundStyle(.secondary)
                    Rectangle().frame(height: 1).foregroundStyle(.separator)
                }
                .padding(.horizontal, 24)

                // Sign in with Apple
                SignInWithAppleButton(
                    viewModel.mode == .signIn ? .signIn : .signUp,
                    onRequest: configureAppleRequest,
                    onCompletion: handleAppleCompletion
                )
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 24)

                // Toggle mode
                Button(action: toggleMode) {
                    Text(viewModel.mode == .signIn
                         ? "Don't have an account? Sign up"
                         : "Already have an account? Sign in")
                        .font(.footnote)
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.bottom, 40)
            }
        }
        .onDisappear { viewModel.discardCapturedCredentials() }
    }

    private var resendConfirmationSection: some View {
        VStack(spacing: 8) {
            Button(action: resendConfirmation) {
                if viewModel.resendStatus == .sending {
                    ProgressView()
                } else {
                    Text("Resend email")
                        .font(.footnote)
                        .fontWeight(.semibold)
                }
            }
            .foregroundStyle(Color.accentColor)
            .disabled(!viewModel.canResendConfirmation)

            if let resendMessage = viewModel.resendMessage {
                Text(resendMessage)
                    .font(.footnote)
                    .foregroundStyle(viewModel.resendStatus == .sent ? Color.secondary : Color.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Previews
}

#Preview {
    AuthView(onAuthenticated: {}, onForgotPassword: { _ in })
}

extension AuthView {
    // MARK: - Email/Password

    private func submitEmailPassword() {
        Task {
            if await viewModel.submit() { onAuthenticated() }
        }
    }

    private func resendConfirmation() {
        Task {
            if await viewModel.resendConfirmation() { onAuthenticated() }
        }
    }

    // MARK: - Sign in with Apple

    private func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else { return }
            Task {
                if await viewModel.signInWithApple(credential: credential) { onAuthenticated() }
            }
        case .failure(let error):
            viewModel.appleAuthorizationFailed(error)
        }
    }

    // MARK: - Helpers

    private func forgotPassword() {
        onForgotPassword(viewModel.email.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func toggleMode() {
        withAnimation { viewModel.toggleMode() }
    }
}

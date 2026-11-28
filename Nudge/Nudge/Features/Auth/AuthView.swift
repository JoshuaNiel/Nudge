import SwiftUI
import AuthenticationServices

struct AuthView: View {
    var onAuthenticated: () -> Void
    /// Sign-up awaits email confirmation, or sign-in was refused as unconfirmed:
    /// show the confirm-email screen.
    var onConfirmationRequired: (PendingEmailConfirmation) -> Void
    /// Opens the reset-password sheet, pre-filled with whatever email is typed.
    var onForgotPassword: (String) -> Void

    @StateObject private var viewModel: AuthViewModel

    init(
        prefillEmail: String = "",
        onAuthenticated: @escaping () -> Void,
        onConfirmationRequired: @escaping (PendingEmailConfirmation) -> Void,
        onForgotPassword: @escaping (String) -> Void
    ) {
        self.onAuthenticated = onAuthenticated
        self.onConfirmationRequired = onConfirmationRequired
        self.onForgotPassword = onForgotPassword
        _viewModel = StateObject(wrappedValue: AuthViewModel(prefillEmail: prefillEmail))
    }

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
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .inputFieldBox()

                    PasswordField(
                        "Password",
                        text: $viewModel.password,
                        textContentType: viewModel.mode == .signIn ? .password : .newPassword
                    )
                    .inputFieldBox()

                    if viewModel.mode == .signUp {
                        PasswordField(
                            "Confirm password",
                            text: $viewModel.confirmPassword,
                            textContentType: .newPassword
                        )
                        .inputFieldBox()
                    }

                    if viewModel.mode == .signIn {
                        Button("Forgot password?", action: forgotPassword)
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 24)

                // Error
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
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
    }

    // MARK: - Previews
}

#Preview {
    AuthView(onAuthenticated: {}, onConfirmationRequired: { _ in }, onForgotPassword: { _ in })
}

extension AuthView {
    // MARK: - Email/Password

    private func submitEmailPassword() {
        Task {
            switch await viewModel.submit() {
            case .signedIn: onAuthenticated()
            case .needsEmailConfirmation(let pending): onConfirmationRequired(pending)
            case .failed: break
            }
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

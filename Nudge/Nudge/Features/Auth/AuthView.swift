import SwiftUI
import AuthenticationServices

struct AuthView: View {
    var onAuthenticated: () -> Void

    @EnvironmentObject private var appState: AppState

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    private enum Mode { case signIn, signUp }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                // Header
                VStack(spacing: 8) {
                    Text("Nudge")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text(mode == .signIn ? "Welcome back" : "Create your account")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 48)

                // Email/password fields
                VStack(spacing: 12) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .textFieldStyle(.roundedBorder)

                    SecureField("Password", text: $password)
                        .textContentType(mode == .signIn ? .password : .newPassword)
                        .textFieldStyle(.roundedBorder)

                    if mode == .signUp {
                        SecureField("Confirm password", text: $confirmPassword)
                            .textContentType(.newPassword)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.horizontal, 24)

                // Error
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Primary action
                Button(action: submitEmailPassword) {
                    Group {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text(mode == .signIn ? "Sign In" : "Sign Up")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isLoading)
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
                    mode == .signIn ? .signIn : .signUp,
                    onRequest: configureAppleRequest,
                    onCompletion: handleAppleCompletion
                )
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 24)

                // Toggle mode
                Button(action: toggleMode) {
                    Text(mode == .signIn
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

#Preview("Sign In") {
    AuthView(onAuthenticated: {})
        .environmentObject(AppState())
}

#Preview("Sign Up") {
    AuthView(onAuthenticated: {})
        .environmentObject(AppState())
}

extension AuthView {
    // MARK: - Email/Password

    private func submitEmailPassword() {
        errorMessage = nil
        guard validate() else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                if mode == .signIn {
                    try await appState.authService.signIn(email: email, password: password)
                } else {
                    try await appState.authService.signUp(email: email, password: password)
                }
                onAuthenticated()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func validate() -> Bool {
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Please fill in all fields."
            return false
        }
        if mode == .signUp, password != confirmPassword {
            errorMessage = "Passwords do not match."
            return false
        }
        return true
    }

    // MARK: - Sign in with Apple

    private func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else { return }
            isLoading = true
            Task {
                defer { isLoading = false }
                do {
                    try await appState.authService.signInWithApple(credential: credential)
                    onAuthenticated()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case .failure(let error):
            // ASAuthorizationError.canceled is not a real error — user dismissed the sheet
            let nsError = error as NSError
            if nsError.code != ASAuthorizationError.canceled.rawValue {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Helpers

    private func toggleMode() {
        withAnimation {
            mode = mode == .signIn ? .signUp : .signIn
            errorMessage = nil
            password = ""
            confirmPassword = ""
        }
    }
}

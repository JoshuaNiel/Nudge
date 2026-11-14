import SwiftUI

/// Sheet: choose a new password after a recovery link has signed the user in.
/// Presented by `NudgeApp` via `AuthRecoveryCoordinator`, above `RootView`, so the
/// sign-in it follows (which re-renders `RootView`) can't dismiss it.
struct SetNewPasswordView: View {
    var onFinished: () -> Void

    @StateObject private var viewModel = SetNewPasswordViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.didSucceed {
                    successContent
                } else {
                    formContent
                }
            }
            .toolbar {
                if !viewModel.didSucceed {
                    ToolbarItem(placement: .cancellationAction) {
                        // The recovery link already signed the user in, so
                        // skipping just keeps the old password.
                        Button("Not now", action: onFinished)
                            .disabled(viewModel.isSaving)
                    }
                }
            }
        }
        // Avoid losing the form to an accidental swipe; "Not now" is the explicit exit.
        .interactiveDismissDisabled(!viewModel.didSucceed)
    }

    private var formContent: some View {
        ScrollView {
            VStack(spacing: 28) {
                // Header
                VStack(spacing: 8) {
                    Text("Set a new password")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Use at least \(PasswordRules.minimumLength) characters.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)

                // Fields
                VStack(spacing: 12) {
                    SecureField("New password", text: $viewModel.newPassword)
                        .textContentType(.newPassword)
                        .textFieldStyle(.roundedBorder)

                    SecureField("Confirm new password", text: $viewModel.confirmPassword)
                        .textContentType(.newPassword)
                        .submitLabel(.done)
                        .onSubmit(submit)
                        .textFieldStyle(.roundedBorder)
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
                Button(action: submit) {
                    Group {
                        if viewModel.isSaving {
                            ProgressView()
                        } else {
                            Text("Update password")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(viewModel.canSubmit ? Color.accentColor : Color.secondary)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!viewModel.canSubmit)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
    }

    private var successContent: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text("Password updated")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("You're signed in. Use your new password next time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            Spacer()
            Button(action: onFinished) {
                Text("Done")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Previews
}

#Preview {
    SetNewPasswordView(onFinished: {})
}

extension SetNewPasswordView {
    // MARK: - Actions

    private func submit() {
        guard viewModel.canSubmit else { return }
        Task { await viewModel.save() }
    }
}

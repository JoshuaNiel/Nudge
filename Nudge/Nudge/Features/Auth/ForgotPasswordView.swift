import SwiftUI

/// Sheet: request a password-reset email. Presented by `NudgeApp` via
/// `AuthRecoveryCoordinator` so it survives `RootView` transitions.
struct ForgotPasswordView: View {
    var onClose: () -> Void

    @StateObject private var viewModel: ForgotPasswordViewModel
    @FocusState private var isEmailFocused: Bool

    init(prefillEmail: String, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _viewModel = StateObject(wrappedValue: ForgotPasswordViewModel(email: prefillEmail))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    // Header
                    VStack(spacing: 8) {
                        Text("Reset your password")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text(ForgotPasswordViewModel.instructionsMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)
                    .padding(.horizontal, 24)

                    // Email field
                    VStack(spacing: 12) {
                        TextField("Email", text: $viewModel.email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.send)
                            .focused($isEmailFocused)
                            .onSubmit(submit)
                            .inputFieldBox()

                        if let validationError = viewModel.validationError {
                            Text(validationError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 24)

                    // Outcome
                    if let statusMessage = viewModel.statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(viewModel.status == .sent ? Color.secondary : Color.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    // Primary action
                    Button(action: submit) {
                        Text(viewModel.status == .sent ? "Resend link" : "Send reset link")
                            .fontWeight(.semibold)
                            .replacedByLoadingIndicator(while: viewModel.isSending, tone: .onFilled)
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(viewModel.status == .sent ? "Done" : "Cancel", action: onClose)
                }
            }
            .onAppear { isEmailFocused = viewModel.email.isEmpty }
        }
    }

    // MARK: - Previews
}

#Preview {
    ForgotPasswordView(prefillEmail: "", onClose: {})
}

extension ForgotPasswordView {
    // MARK: - Actions

    private func submit() {
        guard viewModel.canSubmit else { return }
        Task { await viewModel.submit() }
    }
}

import SwiftUI

/// Settings → Delete Account: password confirmation sheet
/// (docs/specs/account-deletion.md, section C). All state lives in the ViewModel; every
/// control drives it explicitly.
struct DeleteAccountSheet: View {
    @ObservedObject var viewModel: AccountDeletionViewModel
    @EnvironmentObject private var appState: AppState
    @FocusState private var passwordFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(AccountDeletionViewModel.confirmationMessage)
                }

                Section {
                    SecureField("Password", text: $viewModel.password)
                        .textContentType(.password)
                        .focused($passwordFocused)
                } header: {
                    Text("Enter your password to confirm")
                } footer: {
                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        viewModel.confirmDeletion(notifying: appState)
                    } label: {
                        HStack(spacing: 8) {
                            if viewModel.isDeleting {
                                ProgressView()
                            }
                            Text(viewModel.isDeleting ? "Deleting Account…" : "Delete Account")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!viewModel.canSubmit)
                }
            }
            // Field and buttons are inert while the request is in flight.
            .disabled(viewModel.isDeleting)
            .navigationTitle("Delete Account?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelDeletion()
                    }
                    .disabled(viewModel.isDeleting)
                }
            }
            .onAppear { passwordFocused = true }
        }
        .interactiveDismissDisabled(viewModel.isDeleting)
    }
}

#Preview {
    DeleteAccountSheet(viewModel: AccountDeletionViewModel())
        .environmentObject(AppState())
}

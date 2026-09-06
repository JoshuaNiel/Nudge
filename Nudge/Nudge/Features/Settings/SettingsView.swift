import SwiftUI
import Supabase

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject var viewModel = SettingsViewModel()

    private var phoneWarningVisible: Bool {
        !viewModel.phoneNumber.trimmingCharacters(in: .whitespaces).isEmpty && !viewModel.isPhoneValid
    }

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                accountSection
            }
            .navigationTitle("Settings")
        }
        .task {
            if let user = appState.currentUser {
                await viewModel.load(userId: user.id, email: user.email ?? "")
            }
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section {
            TextField("First name", text: $viewModel.firstName)
                .textContentType(.givenName)

            TextField("Last name", text: $viewModel.lastName)
                .textContentType(.familyName)

            VStack(alignment: .leading, spacing: 4) {
                TextField("+18015551234", text: $viewModel.phoneNumber)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)

                if phoneWarningVisible {
                    Text("Enter a valid phone number, e.g. +18015551234.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            saveRow
        } header: {
            Text("Profile")
        } footer: {
            Text("Used only to receive your friend's replies as a text message. You can opt out at any time.")
        }
    }

    private var saveRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task {
                    if let user = appState.currentUser {
                        await viewModel.save(userId: user.id)
                    }
                }
            } label: {
                HStack {
                    Text("Save")
                    if viewModel.isSaving {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!viewModel.canSave)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if viewModel.didSave {
                Text("Saved")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("Account") {
            LabeledContent("Email", value: viewModel.email)

            Button(role: .destructive) {
                Task {
                    try? await appState.authService.signOut()
                }
            } label: {
                Text("Sign Out")
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}

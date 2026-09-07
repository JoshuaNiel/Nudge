import SwiftUI
import Supabase

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject var viewModel = SettingsViewModel()
    @FocusState private var focusedField: Field?

    private enum Field {
        case firstName, lastName, phoneNumber
    }

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                saveSection
                accountSection
            }
            .navigationTitle("Settings")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
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
            labeledField("First Name") {
                TextField("First name", text: $viewModel.firstName)
                    .textContentType(.givenName)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .firstName)
            } error: {
                viewModel.firstNameError
            }

            labeledField("Last Name") {
                TextField("Last name", text: $viewModel.lastName)
                    .textContentType(.familyName)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .lastName)
            } error: {
                viewModel.lastNameError
            }

            labeledField("Phone Number") {
                TextField("+18015551234", text: $viewModel.phoneNumber)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .phoneNumber)
            } error: {
                viewModel.phoneError
            }
        } header: {
            Text("Profile")
        } footer: {
            Text("Phone is optional — used only to receive your friend's replies as a text message. You can opt out at any time.")
        }
    }

    /// A labeled row (leading label, trailing field) with an optional inline error below.
    private func labeledField<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content,
        error: () -> String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .foregroundStyle(.secondary)
                content()
            }
            if let error = error() {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Save

    private var saveSection: some View {
        Section {
            Button {
                focusedField = nil
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
            }
        } footer: {
            if viewModel.didSave {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: viewModel.didSave)
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

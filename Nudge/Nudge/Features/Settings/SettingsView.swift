import SwiftUI
import Supabase

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject var viewModel = SettingsViewModel()
    @StateObject private var deletionViewModel = AccountDeletionViewModel()
    @FocusState private var focusedField: Field?
    @FocusState private var phoneFocused: Bool

    private enum Field {
        case firstName, lastName, phoneNumber
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                profileSection
                nudgesSection
                NotificationSettingsSection()
                deleteAccountSection
            }
            // Nothing else may run (sign out, save) while the account is being deleted.
            .disabled(deletionViewModel.isDeleting)
            .navigationTitle("Settings")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                        phoneFocused = false
                    }
                }
            }
            // NOTE: keyboard-immune "pin like the tab bar" is deferred (see backlog).
            .safeAreaInset(edge: .bottom) {
                saveBar
                    .disabled(deletionViewModel.isDeleting)
            }
        }
        // Every way out of these alerts is a button whose action updates the ViewModel, so
        // the bindings' setters are intentionally no-ops: letting SwiftUI's dismissal write
        // `false` could race the "Delete" action and cancel the confirmation first.
        .alert(
            "Delete Account?",
            isPresented: Binding(get: { deletionViewModel.isConfirming }, set: { _ in })
        ) {
            Button("Delete", role: .destructive) {
                deletionViewModel.confirmDeletion()
            }
            Button("Cancel", role: .cancel) {
                deletionViewModel.cancelDeletion()
            }
        } message: {
            Text(AccountDeletionViewModel.confirmationMessage)
        }
        .alert(
            "Couldn't Delete Account",
            isPresented: Binding(get: { deletionViewModel.errorMessage != nil }, set: { _ in })
        ) {
            Button("OK", role: .cancel) {
                deletionViewModel.dismissError()
            }
        } message: {
            Text(deletionViewModel.errorMessage ?? "")
        }
        .task {
            if let user = appState.currentUser {
                await viewModel.load(userId: user.id, email: user.email ?? "")
            }
        }
    }

    // MARK: - Account (top)

    private var accountSection: some View {
        Section("Account") {
            LabeledContent("Email", value: viewModel.email)

            Button(role: .destructive) {
                Task {
                    try? await appState.signOut()
                }
            } label: {
                Text("Sign Out")
            }
        }
    }

    // MARK: - Delete Account (bottom, separate from Sign Out)

    private var deleteAccountSection: some View {
        Section {
            Button(role: .destructive) {
                focusedField = nil
                phoneFocused = false
                deletionViewModel.requestDeletion()
            } label: {
                HStack(spacing: 8) {
                    if deletionViewModel.isDeleting {
                        ProgressView()
                    }
                    Text(deletionViewModel.isDeleting ? "Deleting Account…" : "Delete Account")
                }
            }
            .disabled(deletionViewModel.isDeleting)
        } footer: {
            Text("Permanently deletes your account and all of its data.")
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
                CountryPhoneField(e164: $viewModel.phoneNumber, focused: $phoneFocused)
            } error: {
                viewModel.phoneError
            }
        } header: {
            Text("Profile")
        } footer: {
            Text("Phone is optional — used only to receive your friend's replies as a text message. You can opt out at any time.")
        }
    }

    // MARK: - Nudges (Phase 5E)

    /// Three sections so each trigger keeps its own footer; the first carries the header.
    /// Changes go through the shared Save bar like the profile fields.
    @ViewBuilder
    private var nudgesSection: some View {
        Section {
            if viewModel.showsNoFriendsNote {
                Label("Add a friend to start sending nudges.", systemImage: "person.badge.plus")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !viewModel.nudgeSettingsLoaded && !viewModel.isLoading {
                Text("Couldn't load your nudge settings.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Toggle("Too much screen time", isOn: $viewModel.nudgeSettings.sessionTimeoutEnabled)
            if viewModel.nudgeSettings.sessionTimeoutEnabled {
                Picker("After", selection: $viewModel.nudgeSettings.sessionTimeoutMinutes) {
                    ForEach(NudgeSettings.allowedSessionTimeoutMinutes, id: \.self) { minutes in
                        Text((minutes * 60).formattedDuration).tag(minutes)
                    }
                }
            }
        } header: {
            Text("Nudges")
        } footer: {
            Text("Friends are nudged after this much total screen time in a day.")
        }
        .disabled(!viewModel.nudgeSettingsLoaded)

        Section {
            Toggle("Goal limit reached", isOn: $viewModel.nudgeSettings.goalBreachEnabled)
        } footer: {
            Text("Friends are nudged when you hit a goal's limit.")
        }
        .disabled(!viewModel.nudgeSettingsLoaded)

        Section {
            Toggle("Daily report", isOn: $viewModel.nudgeSettings.dailyReportEnabled)
            if viewModel.nudgeSettings.dailyReportEnabled {
                DatePicker("Send at", selection: $viewModel.dailyReportDate, displayedComponents: .hourAndMinute)
            }
        } footer: {
            Text("Sent at or after this time, when iOS next runs Nudge. Shows your approximate total screen time for yesterday.")
        }
        .disabled(!viewModel.nudgeSettingsLoaded)
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

    // MARK: - Pinned Save bar (bottom, detached from the scroll)

    private var saveBar: some View {
        VStack(spacing: 8) {
            // Transient feedback above the button.
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if viewModel.didSave {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            Button {
                focusedField = nil
                Task {
                    if let user = appState.currentUser {
                        await viewModel.save(userId: user.id)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isSaving {
                        ProgressView().tint(.white)
                    }
                    Text(viewModel.isSaving ? "Saving…" : "Save")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                // The WHOLE button changes color with state, not just the label.
                .background(viewModel.canSave ? Color.accentColor : Color(.systemGray4))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!viewModel.canSave)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
        .animation(.easeInOut, value: viewModel.didSave)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}

import SwiftUI
import Supabase

// MARK: - AddFriendSheet

/// Adds a friend; inserting the row makes the server send the consent SMS.
struct AddFriendSheet: View {
    var onCompleted: () -> Void

    @EnvironmentObject private var appState: AppState

    @State private var name = ""
    @State private var phoneNumber = ""
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @FocusState private var isInputActive: Bool
    @FocusState private var phoneFocused: Bool

    private var isFormValid: Bool {
        name.isValidFriendName &&
        isValidE164(phoneNumber.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Name").font(.headline).padding(.horizontal, 24)
                        TextField("Friend's name", text: $name)
                            .focused($isInputActive)
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal, 24)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Phone Number").font(.headline).padding(.horizontal, 24)
                        CountryPhoneField(e164: $phoneNumber, focused: $phoneFocused)
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal, 24)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 24)
                    }

                    Button(action: submit) {
                        Group {
                            if isLoading {
                                ProgressView()
                            } else {
                                Text("Send Consent Request")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(!isFormValid ? Color.secondary : Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(!isFormValid || isLoading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }
                .padding(.top, 24)
            }
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCompleted() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isInputActive = false
                        phoneFocused = false
                    }
                }
            }
        }
    }

    private func isValidE164(_ phone: String) -> Bool {
        phone.isValidE164
    }
}

extension AddFriendSheet {
    private func submit() {
        guard let userId = appState.currentUser?.id else { return }
        let trimmedName = name.trimmedFriendName
        let trimmedPhone = phoneNumber.trimmingCharacters(in: .whitespaces)
        errorMessage = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                try await FriendService().addFriend(
                    userId: userId,
                    name: trimmedName,
                    phoneNumber: trimmedPhone
                )
                onCompleted()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

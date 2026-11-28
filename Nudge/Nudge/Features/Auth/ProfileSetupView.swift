import SwiftUI

/// Collects the user's name. Saving goes through the onboarding device copy + outbox
/// (works offline); routing advances as soon as the copy has both names.
struct ProfileSetupView: View {
    /// Called with the untrimmed names; the receiver trims and saves.
    var onSave: (_ firstName: String, _ lastName: String) -> Void

    @State private var firstName: String
    @State private var lastName: String

    init(initialFirstName: String? = nil, initialLastName: String? = nil,
         onSave: @escaping (_ firstName: String, _ lastName: String) -> Void) {
        self.onSave = onSave
        self._firstName = State(initialValue: initialFirstName ?? "")
        self._lastName = State(initialValue: initialLastName ?? "")
    }

    /// Both names must be non-blank (the server enforces the same, migration 004).
    private var isDisabled: Bool {
        firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 8) {
                Text("What's your name?")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("This is how your friends will see you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                TextField("First name", text: $firstName)
                    .textContentType(.givenName)
                    .inputFieldBox()

                TextField("Last name", text: $lastName)
                    .textContentType(.familyName)
                    .inputFieldBox()
            }
            .padding(.horizontal, 24)

            Spacer()

            Button(action: save) {
                Text("Continue")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isDisabled ? Color.secondary : Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(isDisabled)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
}

#Preview {
    ProfileSetupView(onSave: { _, _ in })
}

extension ProfileSetupView {
    // MARK: - Actions

    private func save() {
        guard !isDisabled else { return }
        onSave(firstName, lastName)
    }
}

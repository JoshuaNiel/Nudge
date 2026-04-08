import SwiftUI

struct ProfileSetupView: View {
    var onCompleted: () -> Void

    @EnvironmentObject private var appState: AppState

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

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
                    .textFieldStyle(.roundedBorder)

                TextField("Last name", text: $lastName)
                    .textContentType(.familyName)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 24)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()

            Button(action: save) {
                Group {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Continue")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(firstName.isEmpty || lastName.isEmpty ? Color.secondary : Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(firstName.isEmpty || lastName.isEmpty || isLoading)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    private func save() {
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                try await appState.authService.updateProfile(
                    firstName: firstName.trimmingCharacters(in: .whitespaces),
                    lastName: lastName.trimmingCharacters(in: .whitespaces)
                )
                onCompleted()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    ProfileSetupView(onCompleted: {})
        .environmentObject(AppState())
}

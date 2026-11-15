import SwiftUI
import FamilyControls

/// Picks the app again for an app goal whose stored token no longer decodes (e.g. a
/// selection made on another device). Validation and saving belong to the caller
/// (`GoalsViewModel.reselectApp`), which returns an error message or `nil`.
struct ReselectAppSheet: View {
    // Callbacks
    let goalTitle: String
    var onSave: (FamilyActivitySelection) async -> String?
    var onCompleted: () -> Void

    // Local state
    @State private var selection = FamilyActivitySelection()
    @State private var isSaving = false
    @State private var errorMessage: String? = nil

    private var validationError: String? { GoalTargetValidation.appSelectionError(for: selection) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AppPickerField(selection: $selection)
                } footer: {
                    Text("The app saved for “\(goalTitle)” can't be read on this device. Choose it again to resume tracking.")
                }
                Section {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    PrimaryFormButton(title: "Save", isLoading: isSaving, isDisabled: validationError != nil, action: save)
                }
            }
            .navigationTitle("Re-select App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCompleted)
                        .disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }
}

#Preview {
    ReselectAppSheet(goalTitle: "Instagram", onSave: { _ in nil }, onCompleted: {})
}

extension ReselectAppSheet {
    private func save() {
        errorMessage = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            if let message = await onSave(selection) {
                errorMessage = message
            } else {
                onCompleted()
            }
        }
    }
}

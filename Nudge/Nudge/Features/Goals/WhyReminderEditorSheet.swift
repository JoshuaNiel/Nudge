import SwiftUI

/// Add/edit sheet for a why (Phase 4): multiline message with a counter, and the percent
/// of the limit at which to show it. Validation and saving belong to the caller
/// (`WhyRemindersViewModel`), which returns an error message or `nil`.
struct WhyReminderEditorSheet: View {
    // Callbacks
    let existing: WhyReminder?
    let goalTitle: String
    var onSave: (_ message: String, _ percent: Int) async -> String?
    var onCompleted: () -> Void

    // Local state
    @State private var message: String
    @State private var percent: Int
    @State private var isSaving = false
    @State private var errorMessage: String? = nil
    @FocusState private var messageFocused: Bool

    init(
        existing: WhyReminder?,
        goalTitle: String,
        onSave: @escaping (_ message: String, _ percent: Int) async -> String?,
        onCompleted: @escaping () -> Void
    ) {
        self.existing = existing
        self.goalTitle = goalTitle
        self.onSave = onSave
        self.onCompleted = onCompleted
        _message = State(initialValue: existing?.message ?? "")
        _percent = State(initialValue: existing?.notifyPercent ?? WhyReminderRules.defaultPercent)
    }

    private var length: Int { WhyReminderRules.length(of: WhyReminderRules.normalizedMessage(message)) }
    private var isOverLimit: Bool { length > WhyReminderRules.messageMaxLength }
    private var validationError: String? { WhyReminderRules.validationError(message: message, percent: percent) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("I want to be present with my kids", text: $message, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($messageFocused)
                } header: {
                    Text("Your why")
                } footer: {
                    HStack {
                        Spacer()
                        Text("\(length)/\(WhyReminderRules.messageMaxLength)")
                            .monospacedDigit()
                            .foregroundStyle(isOverLimit ? .red : .secondary)
                            .accessibilityLabel("\(length) of \(WhyReminderRules.messageMaxLength) characters")
                    }
                }

                Section {
                    Picker("Remind me at", selection: $percent) {
                        ForEach(WhyReminderRules.allowedPercents, id: \.self) { value in
                            Text("\(value)%").tag(value)
                        }
                    }
                } footer: {
                    Text(percent == 100
                         ? "Shown when you hit your \(goalTitle) limit, in place of the usual message."
                         : "Shown when you reach \(percent)% of your \(goalTitle) limit.")
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
            .navigationTitle(existing == nil ? "Add a Why" : "Edit Why")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCompleted)
                        .disabled(isSaving)
                }
            }
            .onAppear { if existing == nil { messageFocused = true } }
        }
        .interactiveDismissDisabled(isSaving)
    }
}

#Preview {
    WhyReminderEditorSheet(existing: nil, goalTitle: "Instagram", onSave: { _, _ in nil }, onCompleted: {})
}

extension WhyReminderEditorSheet {
    private func save() {
        errorMessage = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            if let error = await onSave(message, percent) {
                errorMessage = error
            } else {
                onCompleted()
            }
        }
    }
}

import SwiftUI

/// Show/hide state for one `PasswordField` (docs/specs/auth-recovery.md, C4). Pure value
/// type so the toggle rules are unit-testable. Never persisted: each field starts hidden.
struct PasswordVisibility: Equatable {
    /// Which of the two stacked inputs is live.
    enum Variant: Hashable {
        case secure
        case plain
    }

    private(set) var isRevealed = false

    var activeVariant: Variant { isRevealed ? .plain : .secure }

    /// The toggle offers the opposite of the current state.
    var toggleAccessibilityLabel: String { isRevealed ? "Hide password" : "Show password" }
    var toggleSystemImage: String { isRevealed ? "eye.slash" : "eye" }

    mutating func toggle() {
        isRevealed.toggle()
    }

    /// Toggles and returns where keyboard focus should go: the newly active variant if
    /// either variant had focus, otherwise `nil` (toggling never raises the keyboard).
    mutating func toggle(focused: Variant?) -> Variant? {
        toggle()
        return focused == nil ? nil : activeVariant
    }
}

/// A password input with a trailing eye button that switches between a `SecureField`
/// (hidden) and a `TextField` (shown). iOS clears a `SecureField` when the user returns
/// to it and types; revealing lets them keep editing instead.
///
/// Both inputs stay mounted in a `ZStack` and only the active one is visible, so focus
/// can be handed from one to the other when toggling (removing the focused view would
/// drop the keyboard). Apply `.textFieldStyle`, `.submitLabel` and `.onSubmit` to this
/// view as you would to a `SecureField`; they reach both inputs through the environment.
struct PasswordField: View {
    let title: String
    @Binding var text: String
    let textContentType: UITextContentType
    /// Optional external focus, for parents that focus the field programmatically.
    /// A `.focused` modifier on this container would not reach the inner inputs.
    var focused: FocusState<Bool>.Binding?

    @State private var visibility = PasswordVisibility()
    @FocusState private var focusedVariant: PasswordVisibility.Variant?

    init(
        _ title: String,
        text: Binding<String>,
        textContentType: UITextContentType,
        focused: FocusState<Bool>.Binding? = nil
    ) {
        self.title = title
        self._text = text
        self.textContentType = textContentType
        self.focused = focused
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                SecureField(title, text: $text)
                    .configured(for: .secure, active: visibility.activeVariant,
                                contentType: textContentType)
                    .focused($focusedVariant, equals: .secure)

                TextField(title, text: $text)
                    .configured(for: .plain, active: visibility.activeVariant,
                                contentType: textContentType)
                    .focused($focusedVariant, equals: .plain)
            }

            Button(action: toggleVisibility) {
                Image(systemName: visibility.toggleSystemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(visibility.toggleAccessibilityLabel)
        }
        .onChange(of: focused?.wrappedValue) { _, isFocused in
            guard let isFocused else { return }
            if isFocused, focusedVariant == nil {
                focusedVariant = visibility.activeVariant
            } else if !isFocused, focusedVariant != nil {
                focusedVariant = nil
            }
        }
        .onChange(of: focusedVariant) { _, variant in
            let isFocused = variant != nil
            if let focused, focused.wrappedValue != isFocused {
                focused.wrappedValue = isFocused
            }
        }
        .onAppear {
            if focused?.wrappedValue == true { focusedVariant = visibility.activeVariant }
        }
    }

    private func toggleVisibility() {
        focusedVariant = visibility.toggle(focused: focusedVariant)
    }
}

private extension View {
    /// Shared input settings; the inactive input is invisible, untappable, hidden from
    /// VoiceOver and has no content type, so AutoFill sees exactly one password field.
    func configured(
        for variant: PasswordVisibility.Variant,
        active: PasswordVisibility.Variant,
        contentType: UITextContentType
    ) -> some View {
        let isActive = variant == active
        return self
            .textContentType(isActive ? contentType : nil)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }
}

#Preview {
    @Previewable @State var password = ""
    @Previewable @State var confirm = ""
    VStack(spacing: 12) {
        PasswordField("Password", text: $password, textContentType: .newPassword)
        PasswordField("Confirm password", text: $confirm, textContentType: .newPassword)
    }
    .textFieldStyle(.roundedBorder)
    .padding(.horizontal, 24)
}

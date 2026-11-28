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

    /// Only the visible input may write the shared text. Both inputs are bound to the
    /// same value, so the hidden one is refreshed during every view update; a write-back
    /// from it would publish from inside that update.
    func acceptsEdit(from variant: Variant) -> Bool {
        variant == activeVariant
    }

    /// Where focus goes when the field appears.
    func initialFocus(focusOnAppear: Bool) -> Variant? {
        focusOnAppear ? activeVariant : nil
    }
}

/// A password input with an eye button that switches between a `SecureField` (hidden)
/// and a `TextField` (shown). iOS clears a `SecureField` when the user returns to it and
/// types; revealing lets them keep editing instead.
///
/// Both inputs stay mounted in a `ZStack` and only the active one is visible, so focus
/// can be handed from one to the other when toggling (removing the focused view would
/// drop the keyboard). Apply `.submitLabel` and `.onSubmit` to this view as you would to a
/// `SecureField`; they reach both inputs through the environment.
///
/// The view draws no border. Standalone, apply `.inputFieldBox()` so the eye sits inside
/// the same box as the other fields; in a `Form` row, use it as is.
///
/// Focus lives in one place, this view's own `@FocusState`. There is deliberately no
/// external `FocusState` binding: mirroring two focus states with `onChange` in both
/// directions writes focus from inside a focus update, which SwiftUI reports as an
/// AttributeGraph cycle. Parents that want the keyboard up on appear pass `focusOnAppear`.
struct PasswordField: View {
    let title: String
    @Binding var text: String
    let textContentType: UITextContentType
    let focusOnAppear: Bool

    @State private var visibility = PasswordVisibility()
    @FocusState private var focusedVariant: PasswordVisibility.Variant?

    init(
        _ title: String,
        text: Binding<String>,
        textContentType: UITextContentType,
        focusOnAppear: Bool = false
    ) {
        self.title = title
        self._text = text
        self.textContentType = textContentType
        self.focusOnAppear = focusOnAppear
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                SecureField(title, text: input(for: .secure))
                    .configured(for: .secure, active: visibility.activeVariant,
                                contentType: textContentType)
                    .focused($focusedVariant, equals: .secure)

                TextField(title, text: input(for: .plain))
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
        .onAppear {
            if let variant = visibility.initialFocus(focusOnAppear: focusOnAppear) {
                focusedVariant = variant
            }
        }
    }

    /// The shared text, writable only through the visible input.
    private func input(for variant: PasswordVisibility.Variant) -> Binding<String> {
        Binding(
            get: { text },
            set: { newValue in
                guard visibility.acceptsEdit(from: variant), newValue != text else { return }
                text = newValue
            }
        )
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
            .inputFieldBox()
        PasswordField("Confirm password", text: $confirm, textContentType: .newPassword)
            .inputFieldBox()
    }
    .padding(.horizontal, 24)
}

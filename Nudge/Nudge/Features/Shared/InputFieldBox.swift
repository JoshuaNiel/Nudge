import SwiftUI

extension View {
    /// The bordered box that standalone text inputs sit in (sign-in, sign-up, Set New
    /// Password, onboarding). Use it instead of `.textFieldStyle(.roundedBorder)` so a
    /// plain `TextField` and a `PasswordField` (whose eye button sits inside the box)
    /// share one height, corner radius, fill and border.
    ///
    /// Not for `Form` rows: the row is already the container there.
    func inputFieldBox() -> some View {
        modifier(InputFieldBox())
    }
}

private struct InputFieldBox: ViewModifier {
    private static let minHeight: CGFloat = 44
    private static let cornerRadius: CGFloat = 10
    private static let horizontalPadding: CGFloat = 12

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            // The box draws the chrome; inner fields must not add their own border.
            .textFieldStyle(.plain)
            .padding(.horizontal, Self.horizontalPadding)
            .frame(minHeight: Self.minHeight)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
            .overlay {
                shape.strokeBorder(Color(uiColor: .separator), lineWidth: 1)
            }
    }
}

#Preview {
    @Previewable @State var email = ""
    @Previewable @State var password = ""
    VStack(spacing: 12) {
        TextField("Email", text: $email)
            .inputFieldBox()
        PasswordField("Password", text: $password, textContentType: .password)
            .inputFieldBox()
    }
    .padding(.horizontal, 24)
}

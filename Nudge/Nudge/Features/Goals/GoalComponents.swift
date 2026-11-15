import SwiftUI
import FamilyControls
import ManagedSettings

// Small views shared by the Goals list, Goal detail and the Add Goal / Re-select sheets.

/// What a goal limits: the app's real icon + name via `Label(token)` with the user's
/// label underneath; a color dot + category name; or "All Apps".
struct GoalTargetLabel: View {
    let target: GoalItemTarget

    var body: some View {
        switch target {
        case .app(let label, let token):
            if let token {
                VStack(alignment: .leading, spacing: 2) {
                    Label(token)
                        .labelStyle(.titleAndIcon)
                        .font(.headline)
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label(label, systemImage: "app.dashed")
                    .font(.headline)
            }
        case .category(let name, let colorHex):
            HStack(spacing: 10) {
                CategoryColorDot(hex: colorHex)
                Text(name).font(.headline)
            }
        case .total:
            Label("All Apps", systemImage: "iphone")
                .font(.headline)
        }
    }
}

struct CategoryColorDot: View {
    let hex: String
    var size: CGFloat = 14

    var body: some View {
        Circle()
            .fill(Color(hex: hex) ?? Color.accentColor)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The 10-step milestone bar (G3): one segment per 10% the extension has recorded.
struct GoalProgressBar: View {
    let filledSteps: Int
    var isDimmed = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<GoalProgressDisplay.stepCount, id: \.self) { index in
                Capsule()
                    .fill(index < filledSteps ? fillColor : Color.secondary.opacity(0.18))
                    .frame(height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    private var fillColor: Color {
        if isDimmed { return .secondary }
        return filledSteps >= GoalProgressDisplay.stepCount ? .red : .accentColor
    }
}

/// Opens `FamilyActivityPicker` for a single-app goal and shows the chosen app.
struct AppPickerField: View {
    @Binding var selection: FamilyActivitySelection

    @State private var isPickerPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { isPickerPresented = true } label: {
                HStack {
                    chosenApp
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .familyActivityPicker(isPresented: $isPickerPresented, selection: $selection)

            if !SelectionCodec.isEmpty(selection), let message = GoalTargetValidation.appSelectionError(for: selection) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var chosenApp: some View {
        if selection.applicationTokens.count == 1, let token = selection.applicationTokens.first {
            Label(token)
                .labelStyle(.titleAndIcon)
        } else {
            Text(SelectionCodec.isEmpty(selection) ? "Choose an app" : "Change selection")
                .foregroundStyle(Color.accentColor)
        }
    }
}

/// Full-width primary action (docs/conventions.md → Primary Button Style), sized for a
/// `Form` row.
struct PrimaryFormButton: View {
    let title: String
    let isLoading: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                } else {
                    Text(title).fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(isDisabled ? Color.secondary : Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(isDisabled || isLoading)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
}

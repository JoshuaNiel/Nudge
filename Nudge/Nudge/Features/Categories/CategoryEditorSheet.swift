import SwiftUI
import Supabase // `User.id` (Auth module) on `appState.currentUser`
import FamilyControls

/// Create/edit a category (G10): name, preset color, and a `FamilyActivityPicker`
/// selection of apps and/or Apple categories.
struct CategoryEditorSheet: View {
    // Callbacks
    /// The saved category, or `nil` when cancelled.
    var onCompleted: (AppCategory?) -> Void

    // Environment
    @EnvironmentObject private var appState: AppState

    // Local state
    @StateObject private var viewModel: CategoryEditorViewModel
    @State private var isPickerPresented = false

    init(mode: CategoryEditorViewModel.Mode, onCompleted: @escaping (AppCategory?) -> Void) {
        self.onCompleted = onCompleted
        _viewModel = StateObject(wrappedValue: CategoryEditorViewModel(mode: mode))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Social", text: $viewModel.name)
                        .textInputAutocapitalization(.words)
                        .accessibilityLabel("Name")
                }
                Section("Color") {
                    palette
                }
                selectionSection
                saveSection
            }
            .navigationTitle(viewModel.isEditing ? "Edit Category" : "New Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCompleted(nil) }
                        .disabled(viewModel.isSaving)
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isSaving)
        .familyActivityPicker(isPresented: $isPickerPresented, selection: $viewModel.selection)
    }

    // MARK: - Subviews

    private var palette: some View {
        HStack(spacing: 0) {
            ForEach(CategoryPalette.colors, id: \.self) { hex in
                let isSelected = viewModel.color.caseInsensitiveCompare(hex) == .orderedSame
                Button { viewModel.color = hex } label: {
                    ZStack {
                        Circle()
                            .fill(Color(hex: hex) ?? .accentColor)
                            .frame(width: 30, height: 30)
                        if isSelected {
                            Circle()
                                .strokeBorder(Color.primary, lineWidth: 2)
                                .frame(width: 38, height: 38)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(CategoryPalette.name(for: hex))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private var selectionSection: some View {
        Section {
            Button { isPickerPresented = true } label: {
                HStack {
                    Text(SelectionCodec.isEmpty(viewModel.selection) ? "Choose Apps & Categories" : "Edit Apps & Categories")
                    Spacer()
                    Text(viewModel.summaryText)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Apps")
        } footer: {
            if viewModel.selectionNeedsReselect {
                Text("The saved apps can't be read on this device. Choose them again.")
                    .foregroundStyle(.orange)
            } else {
                Text("Pick at least one app or category. Time in all of them counts together.")
            }
        }
    }

    private var saveSection: some View {
        Section {
            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if let hint = viewModel.validationError {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            PrimaryFormButton(
                title: viewModel.isEditing ? "Save Changes" : "Create Category",
                isLoading: viewModel.isSaving,
                isDisabled: !viewModel.canSave,
                action: save
            )
        }
    }
}

#Preview {
    CategoryEditorSheet(mode: .create, onCompleted: { _ in })
        .environmentObject(AppState())
}

extension CategoryEditorSheet {
    // MARK: - Actions

    private func save() {
        guard let userId = appState.currentUser?.id else {
            viewModel.errorMessage = "You're signed out. Sign in and try again."
            return
        }
        Task {
            if let saved = await viewModel.save(userId: userId) { onCompleted(saved) }
        }
    }
}

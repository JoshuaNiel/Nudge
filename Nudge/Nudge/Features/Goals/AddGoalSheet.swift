import SwiftUI
import Supabase // `User.id` (Auth module) on `appState.currentUser`
import FamilyControls

/// Add Goal sheet (Phase 3b): target → daily limit → optional temporary range.
/// Daily only (G6) — there is no frequency choice.
struct AddGoalSheet: View {
    // Callbacks
    /// `true` when a goal was created.
    var onCompleted: (Bool) -> Void

    // Environment
    @EnvironmentObject private var appState: AppState

    // Local state
    @StateObject private var viewModel = AddGoalViewModel()
    @State private var showNewCategory = false

    var body: some View {
        NavigationStack {
            Form {
                targetSection
                switch viewModel.targetType {
                case .app: appSection
                case .category: categorySection
                case .total: totalSection
                }
                limitSection
                durationSection
                saveSection
            }
            .navigationTitle("New Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCompleted(false) }
                        .disabled(viewModel.isSaving)
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isSaving)
        .task { await loadCategories() }
        .onChange(of: viewModel.targetType) { _, _ in viewModel.errorMessage = nil }
        .onChange(of: viewModel.startDate) { _, newStart in
            // Keep the range valid when the start moves past the end.
            if viewModel.endDate < newStart { viewModel.endDate = newStart }
        }
        .sheet(isPresented: $showNewCategory) {
            CategoryEditorSheet(mode: .create) { saved in
                showNewCategory = false
                if let saved { viewModel.categoryCreated(saved) }
            }
            .environmentObject(appState)
        }
    }

    // MARK: - Sections

    private var targetSection: some View {
        Section("What do you want to limit?") {
            Picker("Target", selection: $viewModel.targetType) {
                Text("App").tag(GoalTargetType.app)
                Text("Category").tag(GoalTargetType.category)
                Text("All Apps").tag(GoalTargetType.total)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var appSection: some View {
        Section {
            AppPickerField(selection: $viewModel.appSelection)
            TextField("e.g. Instagram", text: $viewModel.label)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .accessibilityLabel("Name")
        } header: {
            Text("App")
        } footer: {
            Text("Give the app a name. It's used in your reminders and in nudges to friends.")
        }
    }

    @ViewBuilder
    private var categorySection: some View {
        Section {
            if viewModel.isLoadingCategories && viewModel.categories.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if let error = viewModel.categoriesError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.footnote).foregroundStyle(.red)
                    Button("Try Again") { Task { await loadCategories() } }
                }
            } else {
                ForEach(viewModel.categories) { category in
                    Button { viewModel.selectedCategoryId = category.id } label: {
                        HStack(spacing: 12) {
                            CategoryColorDot(hex: category.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.name).foregroundStyle(.primary)
                                Text(CategoryRules.summaryText(encodedSelection: category.selection))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if viewModel.selectedCategoryId == category.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(viewModel.selectedCategoryId == category.id ? .isSelected : [])
                }
            }
            Button { showNewCategory = true } label: {
                Label("New category…", systemImage: "plus")
            }
        } header: {
            Text("Category")
        }
    }

    private var totalSection: some View {
        Section {
            Label("All Apps", systemImage: "iphone")
        } footer: {
            Text("Counts all of your screen time on this iPhone.")
        }
    }

    private var limitSection: some View {
        Section {
            HStack(spacing: 0) {
                Picker("Hours", selection: $viewModel.hours) {
                    ForEach(0..<24, id: \.self) { Text("\($0) h").tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                Picker("Minutes", selection: $viewModel.minutes) {
                    ForEach(0..<60, id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
            }
            .frame(height: 140)
        } header: {
            Text("Daily limit")
        } footer: {
            Text("Between 5 minutes and 23h 59m.")
        }
    }

    @ViewBuilder
    private var durationSection: some View {
        Section {
            Toggle("Temporary goal", isOn: $viewModel.isTemporary.animation())
            if viewModel.isTemporary {
                DatePicker("Start", selection: $viewModel.startDate, in: viewModel.today..., displayedComponents: .date)
                DatePicker("End", selection: $viewModel.endDate, in: viewModel.startDate..., displayedComponents: .date)
            }
        } footer: {
            Text(viewModel.isTemporary
                 ? "The goal is tracked only from the start date through the end date."
                 : "Turn on to limit only a range of days, like an exam week.")
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
                title: "Save Goal",
                isLoading: viewModel.isSaving,
                isDisabled: !viewModel.canSave,
                action: save
            )
        }
    }
}

#Preview {
    AddGoalSheet(onCompleted: { _ in })
        .environmentObject(AppState())
}

extension AddGoalSheet {
    // MARK: - Actions

    private func loadCategories() async {
        guard let userId = appState.currentUser?.id else { return }
        await viewModel.loadCategories(userId: userId)
    }

    private func save() {
        guard let userId = appState.currentUser?.id else {
            viewModel.errorMessage = "You're signed out. Sign in and try again."
            return
        }
        Task {
            if await viewModel.save(userId: userId) { onCompleted(true) }
        }
    }
}

import SwiftUI
import Supabase // `User.id` (Auth module) on `appState.currentUser`

/// Categories tab (G10): named groups of apps and Apple categories that category goals
/// limit together. Replaces the old empty Apps tab.
struct CategoriesView: View {
    // Environment
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    // Local state
    @StateObject private var viewModel = CategoriesViewModel()
    @State private var isAuthorized = DashboardAvailability.isScreenTimeAuthorized()
    @State private var editor: EditorTarget? = nil
    @State private var pendingDelete: AppCategory? = nil

    private enum EditorTarget: Identifiable {
        case create
        case edit(AppCategory)

        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let category): return "edit-\(category.id)"
            }
        }

        var mode: CategoryEditorViewModel.Mode {
            switch self {
            case .create: return .create
            case .edit(let category): return .edit(category)
            }
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Categories")
                .toolbar {
                    if isAuthorized {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { editor = .create } label: {
                                Label("New Category", systemImage: "plus")
                            }
                        }
                    }
                }
        }
        .sheet(item: $editor) { target in
            CategoryEditorSheet(mode: target.mode) { saved in
                editor = nil
                if let saved { viewModel.categorySaved(saved) }
            }
            .environmentObject(appState)
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { category in
            Button("Delete Category", role: .destructive) { delete(category) }
        } message: { _ in
            Text("Goals that use this category will be deleted too.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { viewModel.actionError != nil }, set: { if !$0 { viewModel.actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.actionError ?? "")
        }
        .onAppear(perform: onAppear)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { isAuthorized = DashboardAvailability.isScreenTimeAuthorized() }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var content: some View {
        if !isAuthorized {
            ScreenTimeAccessRequiredView(reason: "Nudge needs Screen Time access to choose apps for your categories. You can turn it on in Settings.")
        } else if viewModel.isLoading && viewModel.categories.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = viewModel.error {
            ContentUnavailableView {
                Label("Something went wrong", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(.bordered)
            }
        } else if viewModel.categories.isEmpty {
            ContentUnavailableView {
                Label("No categories yet", systemImage: "square.grid.2x2")
            } description: {
                Text("Group apps together, like Social or Games, then set one daily limit for the whole group.")
            } actions: {
                Button("New Category") { editor = .create }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                ForEach(viewModel.categories) { category in
                    Button { editor = .edit(category) } label: {
                        CategoryRow(category: category)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // Not `role: .destructive`: that removes the row before the
                        // confirmation is answered.
                        Button { pendingDelete = category } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }
            .refreshable { await load() }
        }
    }
}

#Preview {
    CategoriesView()
        .environmentObject(AppState())
}

extension CategoriesView {
    // MARK: - Actions

    private func onAppear() {
        isAuthorized = DashboardAvailability.isScreenTimeAuthorized()
        Task { await load() }
    }

    private func load() async {
        guard isAuthorized, let userId = appState.currentUser?.id else { return }
        await viewModel.load(userId: userId)
    }

    private func delete(_ category: AppCategory) {
        pendingDelete = nil
        guard let userId = appState.currentUser?.id else { return }
        Task { await viewModel.delete(id: category.id, userId: userId) }
    }
}

// MARK: - CategoryRow

private struct CategoryRow: View {
    let category: AppCategory

    var body: some View {
        HStack(spacing: 12) {
            CategoryColorDot(hex: category.color, size: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.headline)
                Text(CategoryRules.summaryText(encodedSelection: category.selection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

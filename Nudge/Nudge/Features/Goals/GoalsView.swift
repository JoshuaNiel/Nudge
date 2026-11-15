import SwiftUI
import Supabase // `User.id` (Auth module) on `appState.currentUser`
import FamilyControls

// MARK: - GoalsView

/// Goals tab (Phase 3b): daily goals with 10%-step progress from the monitor extension,
/// a detail screen with exact usage, and the Add Goal sheet.
struct GoalsView: View {
    // Environment
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    // Local state
    @StateObject private var viewModel = GoalsViewModel()
    @State private var isAuthorized = DashboardAvailability.isScreenTimeAuthorized()
    @State private var path: [Int] = []
    @State private var sheet: GoalsSheet? = nil

    private enum GoalsSheet: Identifiable {
        case addGoal
        case reselectApp(goalId: Int, title: String)
        case editCategory(AppCategory)

        var id: String {
            switch self {
            case .addGoal: return "add"
            case .reselectApp(let goalId, _): return "reselect-\(goalId)"
            case .editCategory(let category): return "category-\(category.id)"
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Goals")
                .toolbar {
                    if isAuthorized {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { sheet = .addGoal } label: {
                                Label("Add Goal", systemImage: "plus")
                            }
                        }
                    }
                }
                .navigationDestination(for: Int.self) { goalId in
                    detail(for: goalId)
                }
        }
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet)
                .environmentObject(appState)
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
            guard newPhase == .active else { return }
            isAuthorized = DashboardAvailability.isScreenTimeAuthorized()
            viewModel.refreshProgress()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var content: some View {
        if !isAuthorized {
            ScreenTimeAccessRequiredView(reason: "Nudge needs Screen Time access to choose apps and track your goals. You can turn it on in Settings.")
        } else if viewModel.isLoading && viewModel.items.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = viewModel.error {
            ContentUnavailableView {
                Label("Something went wrong", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again", action: reload)
                    .buttonStyle(.bordered)
            }
        } else if viewModel.items.isEmpty {
            ContentUnavailableView {
                Label("No goals yet", systemImage: "target")
            } description: {
                Text("Set a daily limit for an app, a category, or all your screen time.")
            } actions: {
                Button("Add Goal") { sheet = .addGoal }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            goalList
        }
    }

    private var goalList: some View {
        List {
            ForEach(viewModel.items) { item in
                if item.status == .needsReselect {
                    // Tap goes straight to the picker: there is nothing to show until
                    // the selection is fixed.
                    Button { reselect(item) } label: { GoalRow(item: item) }
                        .buttonStyle(.plain)
                } else {
                    NavigationLink(value: item.id) { GoalRow(item: item) }
                }
            }
            .onDelete(perform: deleteGoals)
        }
        .refreshable { await loadGoals() }
    }

    @ViewBuilder
    private func detail(for goalId: Int) -> some View {
        if let item = viewModel.item(id: goalId) {
            GoalDetailView(
                item: item,
                onReselect: { reselect(item) },
                onDelete: { deleteFromDetail(goalId: goalId) }
            )
        } else {
            ContentUnavailableView("Goal not found", systemImage: "target")
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: GoalsSheet) -> some View {
        switch sheet {
        case .addGoal:
            AddGoalSheet { saved in
                self.sheet = nil
                if saved { reload() }
            }
        case .reselectApp(let goalId, let title):
            ReselectAppSheet(
                goalTitle: title,
                onSave: { selection in
                    guard let userId = appState.currentUser?.id else { return "You're signed out. Sign in and try again." }
                    return await viewModel.reselectApp(goalId: goalId, selection: selection, userId: userId)
                },
                onCompleted: { self.sheet = nil }
            )
        case .editCategory(let category):
            CategoryEditorSheet(mode: .edit(category)) { saved in
                self.sheet = nil
                if saved != nil { reload() }
            }
        }
    }
}

// MARK: - Previews

#Preview {
    GoalsView()
        .environmentObject(AppState())
}

// MARK: - Actions

extension GoalsView {

    private func onAppear() {
        isAuthorized = DashboardAvailability.isScreenTimeAuthorized()
        viewModel.refreshProgress()
        // Categories may have been edited or deleted (cascading to goals) in the
        // Categories tab, so refetch whenever the tab comes back.
        reload()
    }

    private func reload() {
        Task { await loadGoals() }
    }

    private func loadGoals() async {
        guard isAuthorized, let userId = appState.currentUser?.id else { return }
        await viewModel.load(userId: userId)
    }

    private func reselect(_ item: GoalListItem) {
        switch item.goal.targetType {
        case .app:
            sheet = .reselectApp(goalId: item.id, title: item.title)
        case .category:
            // The tokens live on the category; fix them there. A missing category
            // (already deleted) cannot be edited — the goal is gone after a refresh.
            if let categoryId = item.goal.categoryId, let category = viewModel.category(id: categoryId) {
                sheet = .editCategory(category)
            } else {
                reload()
            }
        case .total:
            break
        }
    }

    private func deleteGoals(at offsets: IndexSet) {
        guard let userId = appState.currentUser?.id else { return }
        let ids = offsets.map { viewModel.items[$0].id }
        Task {
            for id in ids { await viewModel.deleteGoal(id: id, userId: userId) }
        }
    }

    private func deleteFromDetail(goalId: Int) {
        guard let userId = appState.currentUser?.id else { return }
        Task {
            if await viewModel.deleteGoal(id: goalId, userId: userId) {
                path.removeAll { $0 == goalId }
            }
        }
    }
}

// MARK: - GoalRow

private struct GoalRow: View {
    let item: GoalListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                GoalTargetLabel(target: item.target)
                Spacer(minLength: 8)
                Text(item.limitText)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GoalProgressBar(filledSteps: item.status == .active ? item.filledSteps : 0, isDimmed: item.status != .active)
            HStack(spacing: 4) {
                if item.status == .needsReselect {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                Text(item.caption)
            }
            .font(.caption)
            .foregroundStyle(captionColor)
        }
        .padding(.vertical, 4)
        .opacity(item.status == .active ? 1 : 0.75)
        .accessibilityElement(children: .combine)
    }

    private var captionColor: Color {
        switch item.status {
        case .active: return item.filledSteps >= GoalProgressDisplay.stepCount ? .red : .secondary
        case .needsReselect: return .orange
        case .notMonitored, .notActiveToday: return .secondary
        }
    }
}

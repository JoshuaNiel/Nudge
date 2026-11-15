import SwiftUI
import DeviceActivity
import FamilyControls
import Supabase // `User.id` (Auth module) on `appState.currentUser`

/// Goal detail (G8): exact usage today, drawn by the report extension's `goalUsage`
/// scene, with the limit, the 10%-step milestone bar, the temporary range, the goal's
/// whys (Phase 4) and Delete drawn here around it.
///
/// A `List` (not a `ScrollView`) so the whys get native swipe-to-delete. The Phase 3b
/// cards keep their own look: each sits in a section with a clear, inset-free row.
struct GoalDetailView: View {
    // Callbacks
    let item: GoalListItem
    var onReselect: () -> Void
    var onDelete: () -> Void

    // Environment
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    // Local state
    /// Changing this relaunches the report extension with fresh data.
    @State private var refreshId = UUID()
    @State private var showDeleteConfirmation = false
    @StateObject private var whyViewModel: WhyRemindersViewModel
    @State private var whyEditor: WhyEditor? = nil

    private enum WhyEditor: Identifiable {
        case add
        case edit(WhyReminder)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let reminder): return "edit-\(reminder.id)"
            }
        }
    }

    init(item: GoalListItem, onReselect: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.item = item
        self.onReselect = onReselect
        self.onDelete = onDelete
        _whyViewModel = StateObject(wrappedValue: WhyRemindersViewModel(goalId: item.id))
    }

    /// A real, fixed frame: a zero-size report never launches the extension (ADR-044),
    /// and the host cannot size a remote view to its content.
    private static let reportHeight: CGFloat = 110

    var body: some View {
        List {
            cardSection { header }
            if item.status != .active { cardSection { statusBanner } }
            cardSection { usageCard }
            cardSection { detailsCard }
            WhyRemindersSection(
                viewModel: whyViewModel,
                onAdd: { whyEditor = .add },
                onEdit: { whyEditor = .edit($0) },
                onDelete: deleteWhy,
                onRetry: reloadWhys
            )
            cardSection { deleteButton }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(20)
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this goal?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Goal", role: .destructive, action: onDelete)
        } message: {
            Text("“\(item.title)” will stop being tracked.")
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { refreshId = UUID() }
        }
        .sheet(item: $whyEditor) { editor in
            whyEditorSheet(editor)
        }
        .task { await loadWhys() }
    }

    // MARK: - Layout

    /// One Phase 3b card as its own list section, drawn edge to edge with its own
    /// background and corner radius.
    private func cardSection<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Section {
            content()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func whyEditorSheet(_ editor: WhyEditor) -> some View {
        switch editor {
        case .add:
            WhyReminderEditorSheet(
                existing: nil,
                goalTitle: item.title,
                onSave: { message, percent in
                    guard let userId = appState.currentUser?.id else { return Self.signedOutMessage }
                    return await whyViewModel.add(userId: userId, message: message, percent: percent)
                },
                onCompleted: { whyEditor = nil }
            )
        case .edit(let reminder):
            WhyReminderEditorSheet(
                existing: reminder,
                goalTitle: item.title,
                onSave: { message, percent in
                    guard let userId = appState.currentUser?.id else { return Self.signedOutMessage }
                    return await whyViewModel.update(reminder, userId: userId, message: message, percent: percent)
                },
                onCompleted: { whyEditor = nil }
            )
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            GoalTargetLabel(target: item.target)
            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(item.caption, systemImage: item.status == .needsReselect ? "exclamationmark.circle.fill" : "pause.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(item.status == .needsReselect ? .orange : .secondary)
            Text(statusExplanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if item.status == .needsReselect {
                Button(item.goal.targetType == .app ? "Re-select App" : "Edit Category", action: onReselect)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var usageCard: some View {
        if let filter = usageFilter {
            ZStack {
                // Visible until the extension draws its opaque view over it.
                ProgressView()
                DeviceActivityReport(.goalUsage, filter: filter)
                    .id(refreshId)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.reportHeight)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        } else {
            Text("Exact usage is unavailable until the apps are selected again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: Self.reportHeight)
                .padding(.horizontal)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            row("Daily limit", value: item.goal.limitSeconds.formattedDuration)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Progress")
                    Spacer()
                    Text(GoalProgressDisplay.caption(percent: item.percent))
                        .foregroundStyle(.secondary)
                }
                GoalProgressBar(filledSteps: item.filledSteps, isDimmed: item.status != .active)
                Text("Updates in 10% steps while you use your phone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if let range = item.dateRangeText() {
                row("Active", value: range)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var deleteButton: some View {
        Button(role: .destructive) { showDeleteConfirmation = true } label: {
            Text("Delete Goal")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

extension GoalDetailView {
    // MARK: - Whys

    private static let signedOutMessage = "You're signed out. Sign in and try again."

    private func loadWhys() async {
        guard let userId = appState.currentUser?.id else { return }
        await whyViewModel.load(userId: userId)
    }

    private func reloadWhys() {
        Task { await loadWhys() }
    }

    private func deleteWhy(_ reminder: WhyReminder) {
        guard let userId = appState.currentUser?.id else { return }
        Task { await whyViewModel.delete(reminder, userId: userId) }
    }

    // MARK: - Report filter

    /// Today for the goal's tokens; total goals pass no tokens (= all usage). `nil` when
    /// an app/category goal has no usable selection — an empty filter would report all
    /// usage under the wrong name.
    private var usageFilter: DeviceActivityFilter? {
        let segment = DeviceActivityFilter.SegmentInterval.daily(
            during: GoalUsageDay.filterInterval(now: Date(), calendar: .current)
        )
        switch item.goal.targetType {
        case .total:
            return DeviceActivityFilter(segment: segment)
        case .app, .category:
            guard let selection = item.selection else { return nil }
            return DeviceActivityFilter(
                segment: segment,
                applications: selection.applicationTokens,
                categories: selection.categoryTokens,
                webDomains: selection.webDomainTokens
            )
        }
    }

    // MARK: - Copy

    private var statusExplanation: String {
        switch item.status {
        case .needsReselect:
            return item.goal.targetType == .app
                ? "The saved app can't be read on this device, so this goal isn't being tracked. Choose the app again to resume."
                : "This category's apps can't be read on this device, so this goal isn't being tracked. Edit the category to choose them again."
        case .notMonitored:
            return "Only daily goals are tracked right now."
        case .notActiveToday:
            return "This temporary goal is tracked only on the days in its range."
        case .active:
            return ""
        }
    }
}

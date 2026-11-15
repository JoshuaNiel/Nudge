import SwiftUI
import DeviceActivity
import FamilyControls

/// Phase 2 dashboard: day navigation chrome around a `DeviceActivityReport`.
///
/// The usage itself is rendered by the `NudgeActivityReport` extension in a
/// separate, sandboxed process (ADR-049) — this view owns only the selected day,
/// the refresh token, and the empty states for when no report can be shown.
///
/// **Refresh is a toolbar button, not pull-to-refresh.** The report is a remote
/// view hosted from another process; touches inside it never reach a host
/// `ScrollView`, so a `.refreshable` container would only respond to drags on the
/// thin chrome above it. The report also scrolls itself, and nesting it inside a
/// host scroll view would need a fixed height the host cannot know. A toolbar
/// button (plus an automatic refresh on every return to the foreground) is
/// reliable instead.
struct DashboardView: View {
    // Environment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    // Local state
    /// Always a start of day within `DashboardDay`'s selectable range.
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    /// Changing this rebuilds the report view, which relaunches the extension's
    /// `makeConfiguration` with fresh data.
    @State private var refreshId = UUID()
    @State private var availability = DashboardAvailability.current()

    private struct ReportIdentity: Hashable {
        let day: Date
        let refreshId: UUID
    }

    /// The monitoring schedule is registered asynchronously on foreground (after a
    /// network fetch), so the first check right after launch can lose that race.
    private static let inactiveRecheckAttempts = 5
    private static let inactiveRecheckInterval: Duration = .seconds(2)

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Dashboard")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if availability == .ready {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: refresh) {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            onForeground()
        }
        .task(id: availability) {
            await recheckWhileTrackingInactive()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch availability {
        case .needsAuthorization:
            ContentUnavailableView {
                Label("Screen Time access required", systemImage: "hourglass.badge.plus")
            } description: {
                Text("Nudge needs Screen Time access to show your usage. You can turn it on in Settings.")
            } actions: {
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
            }
        case .trackingInactive:
            ContentUnavailableView {
                Label("Usage tracking not active", systemImage: "chart.bar.xaxis")
            } description: {
                Text("Nudge hasn't started tracking your screen time yet. Make sure you're signed in and connected, then check again.")
            } actions: {
                Button("Check Again", action: updateAvailability)
                    .buttonStyle(.bordered)
            }
        case .ready:
            VStack(spacing: 0) {
                dayNavigator
                Divider()
                report
            }
        }
    }

    private var dayNavigator: some View {
        let calendar = Calendar.current
        let today = Date()
        return HStack {
            Button(action: stepBack) {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .disabled(!DashboardDay.canStepBack(from: selectedDay, today: today, calendar: calendar))
            .accessibilityLabel("Previous day")

            Spacer()

            Text(DashboardDay.title(for: selectedDay, today: today, calendar: calendar, locale: .current))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            Button(action: stepForward) {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .disabled(!DashboardDay.canStepForward(from: selectedDay, today: today, calendar: calendar))
            .accessibilityLabel("Next day")
        }
        .padding(.horizontal, 12)
    }

    private var report: some View {
        ZStack {
            // Visible until the extension draws its (opaque) view over it.
            ProgressView()
            // Keyed on the day too, so a day change always relaunches the
            // extension rather than relying on the report diffing its filter.
            DeviceActivityReport(.nudgeSummary, filter: filter(for: selectedDay))
                .id(ReportIdentity(day: selectedDay, refreshId: refreshId))
        }
        // A real, non-zero frame: a zero-size report never launches the extension (ADR-044).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    DashboardView()
}

extension DashboardView {
    // MARK: - Filter

    /// A full local day (ADR-045: the default filter is zero-length and returns nothing).
    private func filter(for day: Date) -> DeviceActivityFilter {
        DeviceActivityFilter(
            segment: .daily(during: DashboardDay.filterInterval(for: day, calendar: .current))
        )
    }

    // MARK: - Navigation

    private func stepBack() {
        selectedDay = DashboardDay.step(selectedDay, by: -1, today: Date(), calendar: .current)
    }

    private func stepForward() {
        selectedDay = DashboardDay.step(selectedDay, by: 1, today: Date(), calendar: .current)
    }

    // MARK: - Refresh

    private func refresh() {
        refreshId = UUID()
    }

    /// Re-evaluates access and data on every return to the app: the user may have
    /// granted access in Settings, monitoring may have just been registered, and
    /// the usage shown is otherwise stale. Re-clamping also keeps the selection
    /// valid across midnight.
    private func onForeground() {
        updateAvailability()
        selectedDay = DashboardDay.clamp(selectedDay, today: Date(), calendar: .current)
        refresh()
    }

    // MARK: - Availability

    private func updateAvailability() {
        availability = DashboardAvailability.current()
    }

    /// Bounded re-check while monitoring is not yet registered; stops as soon as
    /// the state changes (the task is keyed on `availability`) or attempts run out.
    private func recheckWhileTrackingInactive() async {
        guard availability == .trackingInactive else { return }
        for _ in 0..<Self.inactiveRecheckAttempts {
            try? await Task.sleep(for: Self.inactiveRecheckInterval)
            if Task.isCancelled { return }
            updateAvailability()
            if availability != .trackingInactive { return }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

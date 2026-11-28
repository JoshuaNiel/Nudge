import SwiftUI
import DeviceActivity

/// Phase 2 dashboard: Day | Week and date navigation chrome around one `DeviceActivityReport`.
///
/// The usage itself is rendered by the `NudgeActivityReport` extension in a
/// separate, sandboxed process (ADR-049) — this view owns only the selected period,
/// the rebuild token, and the empty states for when no report can be shown. Totals |
/// Averages and Apps | Categories live inside the report (V4, V5).
///
/// **One report, filter-only changes (V1).** Changing a report's `.id` disconnects the
/// extension's remote view and connects a new one, and that connection sometimes never draws.
/// So day, week and mode changes change only the filter; `.id` is keyed on `refreshId`
/// alone, and forced rebuilds go through `ReportRebuildPolicy` (debounced, coalesced).
///
/// **Refresh is a toolbar button, not pull-to-refresh.** The report is a remote
/// view hosted from another process; touches inside it never reach a host
/// `ScrollView`, so a `.refreshable` container would only respond to drags on the
/// thin chrome above it. The report also scrolls itself, and nesting it inside a
/// host scroll view would need a fixed height the host cannot know. A toolbar
/// button (plus an automatic refresh on every real return to the app) is
/// reliable instead.
///
/// Screen Time status comes from the shared `PermissionStatusStore`, so the Dashboard and
/// the permission banners never disagree (docs/specs/phase-2-dashboard.md D2).
struct DashboardView: View {
    // Environment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var permissions: PermissionStatusStore

    // Local state
    /// Always normalized and within the selectable range (`DashboardCalendar.clamp`).
    @State private var period = DashboardView.navigation().period(containing: Date(), mode: .day)
    /// Changing this rebuilds the report view, which relaunches the extension with fresh data.
    /// Only `rebuilds` (and the transition into `.ready`) change it — never the period (V1).
    @State private var refreshId = UUID()
    @State private var rebuilds = ReportRebuildPolicy()
    /// The report has not drawn after a while; reveals the Reload fallback behind it (V1).
    @State private var isReloadOffered = false
    @State private var isDatePickerShown = false
    @State private var pickerDate = Date()
    /// Resolved on appear and whenever the store's Screen Time status changes.
    @State private var availability = DashboardAvailability.loading
    /// Only a return from the background refreshes automatically, not an `.inactive`
    /// bounce such as Control Center or a system prompt (D3).
    @State private var foregroundGate = ForegroundGate()
    /// The Screen Time prompt is up; blocks a second request from a double tap.
    @State private var isRequestingScreenTime = false

    /// The monitoring schedule is registered asynchronously on foreground (after a
    /// network fetch), so the first check right after launch can lose that race.
    private static let inactiveRecheckAttempts = 5
    private static let inactiveRecheckInterval: Duration = .seconds(2)
    /// V1: long enough that a healthy report has drawn over the fallback.
    private static let reloadOfferDelay: Duration = .seconds(6)

    var body: some View {
        NavigationStack {
            content
                // Notifications banner only; no Screen Time banner here (D1).
                .permissionBanners(for: .dashboard)
                .mainTabHeader(title: "Dashboard")
                .toolbar {
                    if availability == .ready {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: requestRebuild) {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                }
        }
        .onAppear(perform: updateAvailability)
        // `initial`: the view usually first appears while the scene is already active. Feeding
        // that phase to the gate consumes the launch foreground, so a later `.inactive` bounce
        // is never taken for it.
        .onChange(of: scenePhase, initial: true) { oldPhase, newPhase in
            guard foregroundGate.scenePhaseChanged(to: newPhase) else { return }
            // The initial call (old == new) is this view's first appearance: the report is
            // being created right now, so there is nothing stale to rebuild.
            onForeground(rebuild: oldPhase != newPhase)
        }
        // A grant via Allow, a revoke detected mid-session, or the first status read (D2).
        .onChange(of: permissions.screenTime) { updateAvailability() }
        .onChange(of: permissions.isLoaded) { updateAvailability() }
        .task(id: availability) {
            await recheckWhileTrackingInactive()
        }
        // Each request restarts this wait, so back-to-back triggers make one rebuild (V1).
        .task(id: rebuilds.generation) {
            await performPendingRebuild()
        }
        .sheet(isPresented: $isDatePickerShown) {
            DashboardDatePickerSheet(
                selection: $pickerDate,
                range: Self.navigation().pickerRange,
                title: period.mode == .week ? "Choose a Week" : "Choose a Day",
                onDone: commitPickedDate
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch availability {
        case .loading:
            // Before the first status read: no access screen flash on a cold start (D2).
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsAuthorization:
            ContentUnavailableView {
                Label("Screen Time access required", systemImage: "hourglass.badge.plus")
            } description: {
                Text("Nudge needs Screen Time access to show your usage.")
            } actions: {
                Button("Allow", action: requestScreenTime)
                    .buttonStyle(.borderedProminent)
                    .disabled(isRequestingScreenTime)
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
                modePicker
                periodNavigator
                Divider()
                report
            }
        }
    }

    /// V2: Day | Week, above the navigator.
    private var modePicker: some View {
        Picker("Period", selection: Binding(get: { period.mode }, set: switchMode)) {
            ForEach(DashboardMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// V3: `<  [title ▾]  >`; the title opens the date picker.
    private var periodNavigator: some View {
        let navigation = Self.navigation()
        let unit = period.mode == .week ? "week" : "day"
        return HStack {
            Button(action: { step(by: -1) }) {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .disabled(!navigation.canStepBack(period))
            .accessibilityLabel("Previous \(unit)")

            Spacer()

            Button(action: showDatePicker) {
                HStack(spacing: 4) {
                    Text(navigation.title(for: period, locale: .current))
                        .font(.headline)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Choose a \(unit)")

            Spacer()

            Button(action: { step(by: 1) }) {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .disabled(!navigation.canStepForward(period))
            .accessibilityLabel("Next \(unit)")
        }
        .padding(.horizontal, 12)
    }

    private var report: some View {
        ZStack {
            // Visible until the extension draws its (opaque) view over it, which also covers
            // the Reload fallback: that only shows when the report failed to draw (V1).
            VStack(spacing: 12) {
                ProgressView()
                if isReloadOffered {
                    HStack(spacing: 4) {
                        Text("Taking a while?")
                            .foregroundStyle(.secondary)
                        Button("Reload", action: requestRebuild)
                    }
                    .font(.footnote)
                    .transition(.opacity)
                }
            }
            // One instance for the screen's lifetime: the period only changes its filter.
            DeviceActivityReport(.nudgeSummary, filter: filter)
                .id(refreshId)
        }
        // A real, non-zero frame: a zero-size report never launches the extension (ADR-044).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Restarts with every rebuild, and whenever the report is (re)created on screen.
        .task(id: refreshId) {
            await offerReloadIfStillLoading()
        }
    }
}

#Preview {
    DashboardView()
        .environmentObject(PermissionStatusStore())
}

/// V3: a graphical date picker limited to the selectable days, in a medium-detent sheet.
/// The pick applies on Done; swiping the sheet away leaves the selection unchanged.
private struct DashboardDatePickerSheet: View {
    @Binding var selection: Date
    let range: ClosedRange<Date>
    let title: String
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            DatePicker(title, selection: $selection, in: range, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
        }
        .presentationDetents([.medium])
    }
}

extension DashboardView {
    // MARK: - Period

    /// Fresh per use, so "today" is current across midnight.
    fileprivate static func navigation() -> DashboardCalendar {
        DashboardCalendar(calendar: .current, today: Date())
    }

    /// Changes only the report's filter, never its identity (V1).
    private var filter: DeviceActivityFilter {
        DeviceActivityFilter(segment: .daily(during: Self.navigation().filterInterval(for: period)))
    }

    private func step(by count: Int) {
        period = Self.navigation().step(period, by: count)
    }

    private func switchMode(_ mode: DashboardMode) {
        period = Self.navigation().switching(period, to: mode)
    }

    private func showDatePicker() {
        pickerDate = Self.navigation().pickerSelection(for: period)
        isDatePickerShown = true
    }

    private func commitPickedDate() {
        period = Self.navigation().select(pickerDate, mode: period.mode)
        isDatePickerShown = false
    }

    // MARK: - Rebuild (V1)

    /// Toolbar Refresh, Reload and a real foreground all land here; the rebuild itself waits
    /// for the debounce so back-to-back triggers coalesce.
    private func requestRebuild() {
        rebuilds.request(at: .now)
    }

    private func performPendingRebuild() async {
        guard let delay = rebuilds.remainingDelay(at: .now) else { return }
        try? await Task.sleep(for: delay)
        // A newer request cancelled this wait and started its own.
        guard !Task.isCancelled, rebuilds.fire(at: .now) else { return }
        refreshId = UUID()
    }

    private func offerReloadIfStillLoading() async {
        isReloadOffered = false
        try? await Task.sleep(for: Self.reloadOfferDelay)
        guard !Task.isCancelled else { return }
        withAnimation { isReloadOffered = true }
    }

    /// Re-evaluates access and data on every real return to the app (D3): monitoring may
    /// have just been registered, and the usage shown is otherwise stale. Re-clamping also
    /// keeps the selection valid across midnight.
    private func onForeground(rebuild: Bool) {
        period = Self.navigation().clamp(period)
        if rebuild { requestRebuild() }
        // After the request: a transition into `.ready` creates the report fresh and drops it.
        updateAvailability()
    }

    // MARK: - Availability

    /// When the report becomes showable it is created fresh (it was not on screen), so that
    /// creation is the D3 refresh: a pending rebuild is dropped rather than tearing down the
    /// brand-new connection 400 ms later (V1).
    private func updateAvailability() {
        let next = DashboardAvailability.current(screenTime: permissions.screenTime,
                                                 isLoaded: permissions.isLoaded)
        if DashboardAvailability.shouldRefreshOnTransition(from: availability, to: next) {
            rebuilds.cancel()
            refreshId = UUID()
        }
        availability = next
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

    // MARK: - Screen Time access

    /// The shared Screen Time request: always the system prompt, never Settings
    /// (onboarding-progress §5b; D1). The store publishes the outcome, which updates
    /// `availability` through `onChange`.
    private func requestScreenTime() {
        guard !isRequestingScreenTime else { return }
        isRequestingScreenTime = true
        Task {
            await PermissionActionRunner.run(.screenTime, requester: permissions, openURL: { openURL($0) })
            isRequestingScreenTime = false
        }
    }
}

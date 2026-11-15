import SwiftUI
import UIKit

/// Settings → Notifications (Phase 4): the current permission and the one action that can
/// change it. Self-contained (owns its ViewModel) so `SettingsView` only places it.
struct NotificationSettingsSection: View {
    // Environment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    // Local state
    @StateObject private var viewModel = NotificationSettingsViewModel()

    var body: some View {
        Section {
            LabeledContent("Notifications", value: viewModel.rowState.statusText)

            if let title = viewModel.rowState.actionTitle {
                Button(action: performAction) {
                    HStack(spacing: 8) {
                        Text(title)
                        if viewModel.isRequesting { ProgressView() }
                    }
                }
                .disabled(viewModel.isRequesting)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Nudge uses notifications for your whys and when you hit a limit.")
        }
        .task { await viewModel.refresh() }
        // The user may have changed it in the Settings app.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { Task { await viewModel.refresh() } }
        }
    }
}

extension NotificationSettingsSection {
    // MARK: - Actions

    private func performAction() {
        switch viewModel.rowState.action {
        case .openSettings:
            // Opens Nudge's own notification settings page.
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                openURL(url)
            }
        case .requestPermission:
            Task { await viewModel.turnOn() }
        case .none:
            break
        }
    }
}

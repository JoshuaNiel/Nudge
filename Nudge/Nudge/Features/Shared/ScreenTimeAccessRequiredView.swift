import SwiftUI

/// Shown instead of reports and pickers when Screen Time access is not granted
/// (`DashboardAvailability.isScreenTimeAuthorized()`). Used by Dashboard, Goals and
/// Categories so the copy and Settings link stay consistent.
struct ScreenTimeAccessRequiredView: View {
    /// What the screen needs access for, e.g. "…to show your usage."
    let reason: String

    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("Screen Time access required", systemImage: "hourglass.badge.plus")
        } description: {
            Text(reason)
        } actions: {
            Button("Open Settings", action: openSettings)
                .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    ScreenTimeAccessRequiredView(reason: "Nudge needs Screen Time access to track your goals.")
}

extension ScreenTimeAccessRequiredView {
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

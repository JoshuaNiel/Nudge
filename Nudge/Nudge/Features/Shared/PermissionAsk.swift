import SwiftUI
import UIKit

// Banner and in-context permission actions (docs/specs/onboarding-progress.md §5b). The
// banners and the ask sheets share one rule (`PermissionBanners.action`) and one runner.

/// Performs the banner/sheet action for a permission's current status.
@MainActor
enum PermissionActionRunner {

    /// Shows the system prompt, or opens the app's notification settings when notifications
    /// were denied; nothing when granted. Returns the status afterwards (unchanged after
    /// opening Settings: the foreground refresh picks up a change made there).
    @discardableResult
    static func run(_ permission: DevicePermission,
                    requester: PermissionRequesting,
                    openURL: (URL) -> Void) async -> PermissionStatus {
        switch PermissionBanners.action(for: permission, status: requester.status(of: permission)) {
        case .requestAuthorization:
            await requester.request(permission)
        case .openNotificationSettings:
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
        case nil:
            break
        }
        return requester.status(of: permission)
    }
}

/// An in-context ask: a small sheet explaining why a permission is needed right now.
enum PermissionAsk: Hashable {
    /// Tapping + (Add goal) without Screen Time approved.
    case screenTimeForGoals
    /// A goal was just saved with notifications off.
    case notificationsForGoalLimit

    static let notNowTitle = "Not now"

    var permission: DevicePermission {
        switch self {
        case .screenTimeForGoals: .screenTime
        case .notificationsForGoalLimit: .notifications
        }
    }

    var message: String {
        switch self {
        case .screenTimeForGoals: "Nudge needs Screen Time access to track goals."
        case .notificationsForGoalLimit: "Turn on notifications so Nudge can alert you when you hit this limit."
        }
    }
}

/// The ask sheet: icon, message, primary action ("Allow" / "Turn On" / "Open Settings") and
/// "Not now". Presented as a small sheet; the caller owns what each button does.
struct PermissionAskSheet: View {
    let ask: PermissionAsk
    let primaryTitle: String
    let isLoading: Bool
    let onPrimary: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: PermissionBanners.iconName(for: ask.permission))
                .font(.system(size: 40))
                .foregroundStyle(.orange)
                .padding(.top, 32)

            Text(ask.message)
                .font(.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Button(action: onPrimary) {
                    Group {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text(primaryTitle)
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isLoading)

                Button(action: onNotNow) {
                    Text(PermissionAsk.notNowTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .disabled(isLoading)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isLoading)
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        PermissionAskSheet(ask: .notificationsForGoalLimit, primaryTitle: "Open Settings",
                           isLoading: false, onPrimary: {}, onNotNow: {})
    }
}

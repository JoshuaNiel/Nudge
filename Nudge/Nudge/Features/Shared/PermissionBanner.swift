import SwiftUI
import UIKit

// Post-onboarding permission banners (docs/specs/onboarding-progress.md §5): compact,
// non-dismissible, at the top of the affected screens.

enum PermissionBannerScreen {
    case dashboard, goals, friends
}

enum PermissionBannerAction: Equatable {
    /// Never asked: show the system prompt.
    case requestAuthorization
    /// Denied: the app's page in Settings.
    case openAppSettings
    /// Denied: the app's notification settings.
    case openNotificationSettings
}

enum PermissionBanners {

    /// The banners a screen shows, Screen Time first.
    static func visible(on screen: PermissionBannerScreen,
                        screenTime: PermissionStatus,
                        notifications: PermissionStatus) -> [DevicePermission] {
        var result: [DevicePermission] = []
        if screenTime != .granted && screens(for: .screenTime).contains(screen) { result.append(.screenTime) }
        if notifications != .granted && screens(for: .notifications).contains(screen) { result.append(.notifications) }
        return result
    }

    static func screens(for permission: DevicePermission) -> Set<PermissionBannerScreen> {
        switch permission {
        case .screenTime: [.dashboard, .goals]
        case .notifications: [.dashboard, .goals, .friends]
        }
    }

    /// What the button does for a status; `nil` when granted (no banner).
    static func action(for permission: DevicePermission, status: PermissionStatus) -> PermissionBannerAction? {
        switch status {
        case .granted: nil
        case .notDetermined: .requestAuthorization
        case .denied: permission == .screenTime ? .openAppSettings : .openNotificationSettings
        }
    }

    static func message(for permission: DevicePermission) -> String {
        switch permission {
        case .screenTime: "Screen Time access needed. Nudge can't track your usage or goals."
        case .notifications: "Notifications are off. You won't be alerted when you hit a limit."
        }
    }

    static func buttonTitle(for permission: DevicePermission) -> String {
        switch permission {
        case .screenTime: "Allow"
        case .notifications: "Turn On"
        }
    }

    static func iconName(for permission: DevicePermission) -> String {
        switch permission {
        case .screenTime: "hourglass"
        case .notifications: "bell.slash.fill"
        }
    }
}

// MARK: - Views

/// One banner: icon, message, action button.
struct PermissionBanner: View {
    let permission: DevicePermission
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: PermissionBanners.iconName(for: permission))
                .foregroundStyle(.orange)
            Text(PermissionBanners.message(for: permission))
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(PermissionBanners.buttonTitle(for: permission), action: onAction)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    VStack {
        PermissionBanner(permission: .screenTime, onAction: {})
        PermissionBanner(permission: .notifications, onAction: {})
    }
    .padding()
}

/// The banners for one screen, stacked, from the shared `PermissionStatusStore`.
struct PermissionBannerStack: View {
    let screen: PermissionBannerScreen

    @EnvironmentObject private var permissions: PermissionStatusStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        let visible = permissions.isLoaded
            ? PermissionBanners.visible(on: screen, screenTime: permissions.screenTime,
                                        notifications: permissions.notifications)
            : []
        if !visible.isEmpty {
            VStack(spacing: 8) {
                ForEach(visible, id: \.self) { permission in
                    PermissionBanner(permission: permission) { perform(for: permission) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

extension PermissionBannerStack {
    // MARK: - Actions

    private func perform(for permission: DevicePermission) {
        switch PermissionBanners.action(for: permission, status: permissions.status(of: permission)) {
        case .requestAuthorization:
            Task { await permissions.request(permission) }
        case .openAppSettings:
            open(UIApplication.openSettingsURLString)
        case .openNotificationSettings:
            open(UIApplication.openNotificationSettingsURLString)
        case nil:
            break
        }
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        openURL(url)
    }
}

extension View {
    /// Pins the permission banners for `screen` under the navigation bar.
    func permissionBanners(for screen: PermissionBannerScreen) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            PermissionBannerStack(screen: screen)
        }
    }
}

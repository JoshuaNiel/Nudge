import SwiftUI
import UIKit
import os

// Post-onboarding permission banners (docs/specs/onboarding-progress.md §5): compact,
// non-dismissible, first in the page content of the affected screens, below the header (§5c).

enum PermissionBannerScreen {
    case dashboard, goals, friends
}

/// What a banner or in-context ask button does (spec §5b).
enum PermissionBannerAction: Equatable {
    /// Show the system prompt.
    case requestAuthorization
    /// Notifications denied (iOS can't re-prompt): the app's notification settings.
    case openNotificationSettings
}

enum PermissionBanners {

    /// The gap below the navigation bar, and between the banners and the page content.
    /// One value for both, so a banner never doubles the gap (conventions: field-group spacing).
    static let contentSpacing: CGFloat = 12

    /// The banners a screen shows, Screen Time first.
    static func visible(on screen: PermissionBannerScreen,
                        screenTime: PermissionStatus,
                        notifications: PermissionStatus) -> [DevicePermission] {
        var result: [DevicePermission] = []
        if screenTime != .granted && screens(for: .screenTime).contains(screen) { result.append(.screenTime) }
        if notifications != .granted && screens(for: .notifications).contains(screen) { result.append(.notifications) }
        return result
    }

    /// The Dashboard has no Screen Time banner: it shows its own full-screen access state
    /// (docs/specs/phase-2-dashboard.md D1).
    static func screens(for permission: DevicePermission) -> Set<PermissionBannerScreen> {
        switch permission {
        case .screenTime: [.goals]
        case .notifications: [.dashboard, .goals, .friends]
        }
    }

    /// What the button does for a status; `nil` when granted (no banner). Screen Time always
    /// shows the system prompt (never Settings); notifications prompt only when never asked.
    static func action(for permission: DevicePermission, status: PermissionStatus) -> PermissionBannerAction? {
        guard status != .granted else { return nil }
        switch permission {
        case .screenTime: return .requestAuthorization
        case .notifications: return status == .denied ? .openNotificationSettings : .requestAuthorization
        }
    }

    static func message(for permission: DevicePermission) -> String {
        switch permission {
        case .screenTime: "Screen Time access needed. Nudge can't track your usage or goals."
        case .notifications: "Notifications are off. You won't be alerted when you hit a limit."
        }
    }

    static func buttonTitle(for permission: DevicePermission, status: PermissionStatus) -> String {
        switch action(for: permission, status: status) {
        case .openNotificationSettings: "Open Settings"
        case .requestAuthorization, nil: permission == .screenTime ? "Allow" : "Turn On"
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
    let status: PermissionStatus
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: PermissionBanners.iconName(for: permission))
                .foregroundStyle(.orange)
            Text(PermissionBanners.message(for: permission))
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(PermissionBanners.buttonTitle(for: permission, status: status), action: onAction)
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
        PermissionBanner(permission: .screenTime, status: .denied, onAction: {})
        PermissionBanner(permission: .notifications, status: .denied, onAction: {})
    }
    .padding()
}

/// The banners for one screen, stacked, from the shared `PermissionStatusStore`.
struct PermissionBannerStack: View {
    let screen: PermissionBannerScreen

    @EnvironmentObject private var permissions: PermissionStatusStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        let visible = visibleBanners
        // Always present (zero height when empty), so the visibility log below sees every change.
        VStack(spacing: PermissionBanners.contentSpacing) {
            ForEach(visible, id: \.self) { permission in
                PermissionBanner(permission: permission, status: permissions.status(of: permission)) {
                    perform(for: permission)
                }
            }
        }
        .padding(.horizontal, 24)
        // No bottom padding: the content's own top margin (see `permissionBanners`) is the gap.
        .padding(.top, visible.isEmpty ? 0 : PermissionBanners.contentSpacing)
        .onChange(of: visible) { _, newValue in
            PermissionLog.logger.log("""
                banners on \(String(describing: screen), privacy: .public): \
                \(newValue.isEmpty ? "none" : newValue.map(\.rawValue).joined(separator: ", "), privacy: .public)
                """)
        }
    }

    private var visibleBanners: [DevicePermission] {
        guard permissions.isLoaded else { return [] }
        return PermissionBanners.visible(on: screen, screenTime: permissions.screenTime,
                                         notifications: permissions.notifications)
    }
}

extension PermissionBannerStack {
    // MARK: - Actions

    private func perform(for permission: DevicePermission) {
        Task {
            await PermissionActionRunner.run(permission, requester: permissions, openURL: { openURL($0) })
        }
    }
}

extension View {
    /// Puts the permission banners for `screen` first in the page content, below the
    /// navigation bar (spec §5c), above whatever the screen shows (content, empty, loading or
    /// error state), which fills the rest. Nothing is added when no banner applies.
    ///
    /// Scrolling content (the Goals and Friends lists) also gets a top content margin. An
    /// inset-grouped `List` whose first section has no header starts its first row exactly at
    /// the navigation bar's bottom edge; with the always-visible header (§5c) that reads as
    /// touching it, and below a banner the list starts right at the banner. The margin sits
    /// inside the scroll view (on top of the safe-area inset when the list runs under the
    /// bar), so it scrolls away like the native inset, applies with or without banners, and
    /// is the only gap below a banner. Non-scrolling states (empty, loading, error) center
    /// themselves and are unaffected. Applied to this content only, so sheets and pushed
    /// screens attached after this modifier keep their own margins.
    func permissionBanners(for screen: PermissionBannerScreen) -> some View {
        VStack(spacing: 0) {
            PermissionBannerStack(screen: screen)
            contentMargins(.top, PermissionBanners.contentSpacing, for: .scrollContent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

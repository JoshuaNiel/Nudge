import SwiftUI

/// Asks for the device permissions that were never asked on this device, one page each
/// (docs/specs/onboarding-progress.md §4, §5b). Shown at most once per device: whatever the
/// user does on a page (Allow, Deny, Skip for now) moves past it, and once nothing is left the
/// screen calls `onFinished`.
struct PermissionsView: View {
    /// Never-asked permissions, in order.
    let pending: [DevicePermission]
    /// Shows the system prompt; returns when the user has answered.
    var onRequest: (DevicePermission) async -> Void
    var onFinished: () -> Void

    @State private var isRequesting = false
    /// Pages already answered or skipped on this screen. Screen-local: the page is never shown
    /// again on this device, so nothing needs remembering beyond it.
    @State private var dismissed: Set<DevicePermission> = []

    /// The first pending permission not yet answered or skipped here; `nil` when done.
    static func currentPage(pending: [DevicePermission], dismissed: Set<DevicePermission>) -> DevicePermission? {
        pending.first { !dismissed.contains($0) }
    }

    var body: some View {
        if let permission = Self.currentPage(pending: pending, dismissed: dismissed) {
            page(for: permission)
                .id(permission)
        } else {
            // Nothing left to ask (or nothing was ever pending): finish.
            Color.clear
                .onAppear(perform: onFinished)
        }
    }

    @ViewBuilder
    private func page(for permission: DevicePermission) -> some View {
        switch permission {
        case .screenTime:
            PermissionPageView(
                icon: "hourglass",
                title: "Track Your Screen Time",
                description: "Nudge needs Screen Time access to monitor your app usage. This is the core feature — without it, tracking and goal enforcement won't work.",
                primaryLabel: "Enable Screen Time",
                skipLabel: "Skip for now",
                warning: "You can enable this later in Settings, but the app won't track usage until you do.",
                isLoading: isRequesting,
                onPrimary: { request(.screenTime) },
                onSkip: { skip(.screenTime) }
            )
        case .notifications:
            PermissionPageView(
                icon: "bell.badge.fill",
                title: "Stay on Track",
                description: "Get alerts when you've hit a time limit, reminders of your goals, and nudges from friends.",
                primaryLabel: "Enable Notifications",
                skipLabel: "Skip for now",
                warning: nil,
                isLoading: isRequesting,
                onPrimary: { request(.notifications) },
                onSkip: { skip(.notifications) }
            )
        }
    }
}

#Preview("Screen Time Step") {
    PermissionsView(pending: [.screenTime, .notifications], onRequest: { _ in }, onFinished: {})
}

extension PermissionsView {
    // MARK: - Actions

    private func request(_ permission: DevicePermission) {
        guard !isRequesting else { return }
        isRequesting = true
        Task {
            defer { isRequesting = false }
            await onRequest(permission)
            // Answered (or the request failed without an answer): either way, move on so the
            // screen can't get stuck on this page.
            dismissed.insert(permission)
        }
    }

    private func skip(_ permission: DevicePermission) {
        dismissed.insert(permission)
    }
}

private struct PermissionPageView: View {
    let icon: String
    let title: String
    let description: String
    let primaryLabel: String
    let skipLabel: String
    let warning: String?
    let isLoading: Bool
    let onPrimary: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 64))
                    .foregroundStyle(Color.accentColor)

                Text(title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            Spacer()

            VStack(spacing: 12) {
                Button(action: onPrimary) {
                    Group {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text(primaryLabel)
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

                Button(action: onSkip) {
                    Text(skipLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .disabled(isLoading)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
}

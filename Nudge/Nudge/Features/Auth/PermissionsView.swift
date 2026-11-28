import SwiftUI

/// Asks for the device permissions that were never asked on this device, one page each
/// (docs/specs/onboarding-progress.md §4). Driven by its parent: `pending` shrinks as each
/// permission is answered or skipped, and once it is empty the screen calls `onFinished`.
struct PermissionsView: View {
    /// Never-asked permissions still to show, in order.
    let pending: [DevicePermission]
    /// Shows the system prompt; returns when the user has answered.
    var onRequest: (DevicePermission) async -> Void
    var onSkip: (DevicePermission) -> Void
    var onFinished: () -> Void

    @State private var isRequesting = false

    var body: some View {
        if let permission = pending.first {
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
                onSkip: { onSkip(.screenTime) }
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
                onSkip: { onSkip(.notifications) }
            )
        }
    }
}

#Preview("Screen Time Step") {
    PermissionsView(pending: [.screenTime, .notifications], onRequest: { _ in }, onSkip: { _ in }, onFinished: {})
}

extension PermissionsView {
    // MARK: - Actions

    private func request(_ permission: DevicePermission) {
        guard !isRequesting else { return }
        isRequesting = true
        Task {
            defer { isRequesting = false }
            await onRequest(permission)
        }
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

import SwiftUI
import UserNotifications

struct PermissionsView: View {
    var onCompleted: () -> Void

    @State private var step: Step = .screenTime

    private enum Step { case screenTime, notifications }

    var body: some View {
        switch step {
        case .screenTime:
            PermissionPageView(
                icon: "hourglass",
                title: "Track Your Screen Time",
                description: "Nudge needs Screen Time access to monitor your app usage. This is the core feature — without it, tracking and goal enforcement won't work.",
                primaryLabel: "Enable Screen Time",
                skipLabel: "Skip for now",
                warning: "You can enable this later in Settings, but the app won't track usage until you do.",
                onPrimary: requestScreenTime,
                onSkip: { step = .notifications }
            )
        case .notifications:
            PermissionPageView(
                icon: "bell.badge.fill",
                title: "Stay on Track",
                description: "Get alerts when you've hit a time limit, reminders of your goals, and nudges from friends.",
                primaryLabel: "Enable Notifications",
                skipLabel: "Skip for now",
                warning: nil,
                onPrimary: requestNotifications,
                onSkip: onCompleted
            )
        }
    }

    private func requestScreenTime() {
        // Family Controls authorization is requested via AuthorizationCenter.
        // This requires the Family Controls entitlement — implementation in Phase 1 (DeviceActivity setup).
        // For now, advance to the next step.
        step = .notifications
    }

    private func requestNotifications() {
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            await MainActor.run { onCompleted() }
        }
    }
}

#Preview("Screen Time Step") {
    PermissionsView(onCompleted: {})
}

private struct PermissionPageView: View {
    let icon: String
    let title: String
    let description: String
    let primaryLabel: String
    let skipLabel: String
    let warning: String?
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
                    Text(primaryLabel)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button(action: onSkip) {
                    Text(skipLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
}

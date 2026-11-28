import SwiftUI

// MARK: - NudgeHistoryContent

/// One accepted friend's nudge history (the body of the friend screen). Live while visible:
/// `.task` runs the view model's realtime subscription (cancelled — and the channel removed —
/// when the screen disappears). The view model is owned by `FriendDetailViewModel`, which only
/// creates it for an accepted friend.
struct NudgeHistoryContent: View {
    @ObservedObject var viewModel: NudgeHistoryViewModel

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if viewModel.isLoading {
                NudgeLoadingIndicator()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.error {
                // Scrollable so pull-to-refresh can retry.
                ScrollView {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                        .containerRelativeFrame([.horizontal, .vertical])
                }
            } else if viewModel.nudges.isEmpty {
                ScrollView {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No nudges sent yet.")
                            .foregroundStyle(.secondary)
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
                }
            } else {
                List(viewModel.nudges) { nudge in
                    NudgeHistoryRow(nudge: nudge)
                }
            }
        }
        .refreshable { await viewModel.refresh() }
        .task { await viewModel.start() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await viewModel.sceneDidBecomeActive() }
        }
    }
}

// MARK: - NudgeHistoryRow

private struct NudgeHistoryRow: View {
    let nudge: Nudge

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(nudge.type?.displayName ?? "Awaiting reply", systemImage: nudge.type?.icon ?? "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(nudge.sentTimestamp, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(nudge.prompt)
                .font(.subheadline)
            if let reply = nudge.friendReply {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Text(reply)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
                .padding(.top, 2)
            }
            Text(nudge.status.displayName)
                .font(.caption2)
                .foregroundStyle(nudge.status.color)
                .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - NudgeType + NudgeStatus display helpers

private extension NudgeType {
    var displayName: String {
        switch self {
        case .shame:         return "Shame"
        case .encouragement: return "Encouragement"
        case .custom:        return "Custom"
        }
    }

    var icon: String {
        switch self {
        case .shame:         return "hand.raised"
        case .encouragement: return "star.fill"
        case .custom:        return "pencil"
        }
    }
}

private extension NudgeStatus {
    var displayName: String {
        switch self {
        case .sentToFriend:    return "Sent"
        case .replied:         return "Friend replied"
        case .replyDelivered:  return "Reply delivered"
        case .failed:          return "Failed to send"
        }
    }

    var color: Color {
        switch self {
        case .sentToFriend:    return .secondary
        case .replied:         return .blue
        case .replyDelivered:  return .green
        case .failed:          return .red
        }
    }
}

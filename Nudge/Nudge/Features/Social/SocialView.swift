import SwiftUI
import Supabase

// MARK: - SocialRoute

/// Value-based destinations for the Friends NavigationStack (lets a push deep link set the path).
private enum SocialRoute: Hashable {
    case nudgeHistory(Friend)
}

// MARK: - SocialView

struct SocialView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var pushRouter: PushRouter
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = SocialViewModel()

    @State private var showAddFriend = false
    @State private var path: [SocialRoute] = []
    /// True once the first friend-list load has finished; deep links wait for it.
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = viewModel.error {
                    errorView(message: errorMessage)
                } else if viewModel.friends.isEmpty {
                    emptyState
                } else {
                    friendList
                }
            }
            .navigationTitle("Friends")
            .navigationDestination(for: SocialRoute.self) { route in
                switch route {
                case .nudgeHistory(let friend):
                    NudgeHistoryView(friend: friend)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddFriend = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $showAddFriend) {
                AddFriendSheet {
                    showAddFriend = false
                    guard let userId = appState.currentUser?.id else { return }
                    // Realtime delivers the INSERT too; the silent refetch covers a dead socket.
                    Task { await viewModel.refresh(userId: userId) }
                }
                .environmentObject(appState)
            }
            .refreshable {
                guard let userId = appState.currentUser?.id else { return }
                await viewModel.refresh(userId: userId)
            }
            // Live while the list is on screen: `.task` is cancelled — and the realtime channel
            // removed — when the list disappears (tab switch, history pushed on top).
            .task {
                guard let userId = appState.currentUser?.id else { return }
                await viewModel.start(userId: userId) {
                    hasLoaded = true
                    // Cold start / tab switch: a push tap may be waiting for the list to load.
                    await openPendingDeepLink()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await viewModel.sceneDidBecomeActive() }
            }
            // Warm start while this view already exists: act on a new tap immediately.
            .onChange(of: pushRouter.pendingRoute) { _, route in
                guard route != nil, hasLoaded else { return }
                Task { await openPendingDeepLink() }
            }
        }
    }

    // MARK: - Subviews

    /// Scrollable so pull-to-refresh works from the empty state too.
    private var emptyState: some View {
        ScrollView {
            emptyStateContent
                .containerRelativeFrame([.horizontal, .vertical])
        }
    }

    private var emptyStateContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No friends yet")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Add a friend to send accountability nudges.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showAddFriend = true
            } label: {
                Text("Add Friend")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
        .padding(.horizontal, 24)
    }

    private var friendList: some View {
        List {
            let accepted = viewModel.friends.filter { $0.status == .accepted }
            let pending = viewModel.friends.filter { $0.status == .pending }

            if !accepted.isEmpty {
                Section("Friends") {
                    ForEach(accepted) { friend in
                        // A Button appending to `path`, not `NavigationLink(value:)`: with a
                        // programmatic path the link's row stayed highlighted after going back.
                        Button {
                            path.append(.nudgeHistory(friend))
                        } label: {
                            AcceptedFriendRow(friend: friend)
                        }
                    }
                    .onDelete { indexSet in
                        deleteFriends(from: accepted, at: indexSet)
                    }
                }
            }

            if !pending.isEmpty {
                Section("Pending") {
                    ForEach(pending) { friend in
                        PendingFriendRow(friend: friend)
                    }
                    .onDelete { indexSet in
                        deleteFriends(from: pending, at: indexSet)
                    }
                }
            }
        }
    }

    /// Scrollable so pull-to-refresh can retry.
    private func errorView(message: String) -> some View {
        ScrollView {
            errorContent(message: message)
                .containerRelativeFrame([.horizontal, .vertical])
        }
    }

    private func errorContent(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Something went wrong")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }
}

// MARK: - Actions

extension SocialView {
    // MARK: - Push deep link

    /// Acts on a tapped push. A reply opens the history of the friend the nudge belongs to; if
    /// the nudge or friend can't be resolved, the user simply stays on the friend list — no
    /// error shown. A friend-accepted push shows the list itself (no history opened).
    private func openPendingDeepLink() async {
        guard let userId = appState.currentUser?.id,
              let route = pushRouter.consumePendingRoute() else { return }
        switch route {
        case .nudgeReply(let nudgeId):
            guard let friend = await viewModel.friendForNudge(id: nudgeId, userId: userId) else { return }
            path = [.nudgeHistory(friend)]
        case .friendAccepted:
            path = []
            // Realtime normally has the row already; this covers a channel that isn't joined.
            await viewModel.refresh(userId: userId)
        }
    }

    // MARK: - Friends

    private func deleteFriends(from list: [Friend], at offsets: IndexSet) {
        for index in offsets {
            let friend = list[index]
            Task { await viewModel.deleteFriend(friend) }
        }
    }
}

// MARK: - Preview

#Preview {
    SocialView()
        .environmentObject(AppState())
        .environmentObject(PushRouter())
}

// MARK: - AcceptedFriendRow

/// Tappable row (the label of a `Button`): styled to look like a `NavigationLink` row,
/// including the trailing disclosure chevron.
private struct AcceptedFriendRow: View {
    let friend: Friend

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.friendName)
                    .font(.body)
                    .fontWeight(.medium)
                Text(friend.friendPhoneNumber)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .foregroundStyle(.primary)   // a List Button would otherwise tint the label
        .contentShape(Rectangle())
    }
}

// MARK: - PendingFriendRow

private struct PendingFriendRow: View {
    let friend: Friend

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.friendName)
                    .font(.body)
                    .fontWeight(.medium)
                Text(friend.friendPhoneNumber)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Awaiting consent")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }
}

// MARK: - AddFriendSheet

private struct AddFriendSheet: View {
    var onCompleted: () -> Void

    @EnvironmentObject private var appState: AppState

    @State private var name = ""
    @State private var phoneNumber = ""
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @FocusState private var isInputActive: Bool
    @FocusState private var phoneFocused: Bool

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        isValidE164(phoneNumber.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Name").font(.headline).padding(.horizontal, 24)
                        TextField("Friend's name", text: $name)
                            .focused($isInputActive)
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal, 24)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Phone Number").font(.headline).padding(.horizontal, 24)
                        CountryPhoneField(e164: $phoneNumber, focused: $phoneFocused)
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal, 24)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 24)
                    }

                    Button(action: submit) {
                        Group {
                            if isLoading {
                                ProgressView()
                            } else {
                                Text("Send Consent Request")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(!isFormValid ? Color.secondary : Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(!isFormValid || isLoading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }
                .padding(.top, 24)
            }
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCompleted() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isInputActive = false
                        phoneFocused = false
                    }
                }
            }
        }
    }

    private func isValidE164(_ phone: String) -> Bool {
        phone.isValidE164
    }
}

extension AddFriendSheet {
    private func submit() {
        guard let userId = appState.currentUser?.id else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedPhone = phoneNumber.trimmingCharacters(in: .whitespaces)
        errorMessage = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                try await FriendService().addFriend(
                    userId: userId,
                    name: trimmedName,
                    phoneNumber: trimmedPhone
                )
                onCompleted()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - NudgeHistoryView

/// One friend's nudge history. Live while visible: `.task` runs the view model's realtime
/// subscription (cancelled — and the channel removed — when the screen disappears).
private struct NudgeHistoryView: View {
    let friend: Friend

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: NudgeHistoryViewModel

    init(friend: Friend) {
        self.friend = friend
        _viewModel = StateObject(wrappedValue: NudgeHistoryViewModel(friendId: friend.id))
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
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
        .navigationTitle(friend.friendName)
        .navigationBarTitleDisplayMode(.inline)
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

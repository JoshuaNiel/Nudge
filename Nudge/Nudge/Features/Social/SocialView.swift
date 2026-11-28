import SwiftUI
import Supabase

// MARK: - SocialRoute

/// Value-based destinations for the Friends NavigationStack (lets a push deep link set the path).
/// Routes carry the friend's id, not a `Friend` copy: the friend screen reads the friend live
/// from `SocialViewModel`, so status changes and renames show while it's open.
private enum SocialRoute: Hashable {
    case friend(id: Int)
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
            .permissionBanners(for: .friends)
            .navigationTitle("Friends")
            .mainTabHeader()
            .navigationDestination(for: SocialRoute.self) { route in
                switch route {
                case .friend(let id):
                    FriendDetailView(friendId: id, socialViewModel: viewModel) {
                        path.removeAll { $0 == route }
                    }
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
        }
        // Live while the Friends tab is on screen — the list *and* a friend screen pushed on it,
        // which reads its friend from this list. On the stack, not the list, so pushing a friend
        // keeps the channel; `.task` is cancelled (and the channel removed) on a tab switch.
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
                        friendButton(friend)
                    }
                    .onDelete { indexSet in
                        deleteFriends(from: accepted, at: indexSet)
                    }
                }
            }

            if !pending.isEmpty {
                Section("Pending") {
                    ForEach(pending) { friend in
                        friendButton(friend)
                    }
                    .onDelete { indexSet in
                        deleteFriends(from: pending, at: indexSet)
                    }
                }
            }
        }
    }

    /// A `Button` appending to `path`, not `NavigationLink(value:)`: with a programmatic path the
    /// link's row stayed highlighted after going back. `.plain` keeps the label's own colours
    /// instead of the button tint.
    private func friendButton(_ friend: Friend) -> some View {
        Button {
            path.append(.friend(id: friend.id))
        } label: {
            FriendRow(friend: friend)
        }
        .buttonStyle(.plain)
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

    /// Acts on a tapped push. A reply opens the friend screen (with its history) of the friend
    /// the nudge belongs to; if
    /// the nudge or friend can't be resolved, the user simply stays on the friend list — no
    /// error shown. A friend-accepted push shows the list itself (no history opened).
    private func openPendingDeepLink() async {
        guard let userId = appState.currentUser?.id,
              let route = pushRouter.consumePendingRoute() else { return }
        switch route {
        case .nudgeReply(let nudgeId):
            guard let friend = await viewModel.friendForNudge(id: nudgeId, userId: userId) else { return }
            path = [.friend(id: friend.id)]
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
        .environmentObject(PermissionStatusStore())
}

// MARK: - FriendRow

/// A friend in the list (accepted or pending), used as a plain `Button` label: primary name,
/// secondary phone number, an "Awaiting consent" badge while pending, and a trailing chevron.
private struct FriendRow: View {
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
            if friend.status == .pending {
                Text("Awaiting consent")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())  // the whole row is tappable, not just the text
    }
}

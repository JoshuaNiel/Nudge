import SwiftUI
import Supabase

// MARK: - SocialView

struct SocialView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = SocialViewModel()

    @State private var showAddFriend = false

    var body: some View {
        NavigationStack {
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
                    Task { await viewModel.load(userId: userId) }
                }
                .environmentObject(appState)
            }
            .task {
                guard let userId = appState.currentUser?.id else { return }
                await viewModel.load(userId: userId)
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var friendList: some View {
        List {
            let accepted = viewModel.friends.filter { $0.status == .accepted }
            let pending = viewModel.friends.filter { $0.status == .pending }

            if !accepted.isEmpty {
                Section("Friends") {
                    ForEach(accepted) { friend in
                        NavigationLink {
                            NudgeHistoryView(friend: friend)
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

    private func errorView(message: String) -> some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Actions

extension SocialView {
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
}

// MARK: - AcceptedFriendRow

private struct AcceptedFriendRow: View {
    let friend: Friend

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(friend.friendName)
                .font(.body)
                .fontWeight(.medium)
            Text(friend.friendPhoneNumber)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
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
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal, 24)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Phone Number").font(.headline).padding(.horizontal, 24)
                        TextField("+1 (801) 555-1234", text: $phoneNumber)
                            .keyboardType(.phonePad)
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal, 24)
                        Text("International format required, e.g. +18015551234")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCompleted() }
                }
            }
        }
    }

    private func isValidE164(_ phone: String) -> Bool {
        let pattern = #"^\+[1-9]\d{7,14}$"#
        return phone.range(of: pattern, options: .regularExpression) != nil
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

private struct NudgeHistoryView: View {
    let friend: Friend

    @State private var nudges: [Nudge] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
            } else if nudges.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No nudges sent yet.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(nudges) { nudge in
                    NudgeHistoryRow(nudge: nudge)
                }
            }
        }
        .navigationTitle(friend.friendName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadHistory() }
    }

    private func loadHistory() async {
        isLoading = true
        defer { isLoading = false }
        do {
            nudges = try await FriendService().fetchNudgeHistory(friendId: friend.id)
        } catch {
            errorMessage = error.localizedDescription
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

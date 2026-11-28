import SwiftUI

// MARK: - FriendDetailView

/// One friend's screen (pending or accepted): header, the live history or the awaiting-consent
/// state, rename, and remove. The friend is read live from the shared `SocialViewModel`; when it
/// is blocked, removed, or disappears from the list, `onGone` is called so the parent pops it.
struct FriendDetailView: View {
    var onGone: () -> Void

    @StateObject private var viewModel: FriendDetailViewModel

    @State private var showRename = false
    @State private var confirmRemove = false

    init(friendId: Int, socialViewModel: SocialViewModel, onGone: @escaping () -> Void) {
        self.onGone = onGone
        _viewModel = StateObject(
            wrappedValue: FriendDetailViewModel(friendId: friendId, socialViewModel: socialViewModel)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let friend = viewModel.content.friend {
                header(friend)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if viewModel.content.friend != nil {
                removeSection
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showRename = true }
                    .disabled(viewModel.content.friend == nil || viewModel.isRemoving)
            }
        }
        .sheet(isPresented: $showRename) {
            RenameFriendSheet(
                name: viewModel.content.friend?.friendName ?? "",
                onSave: { try await viewModel.rename(to: $0) },
                onCompleted: { showRename = false }
            )
        }
        .alert(
            "Remove \(viewModel.content.friend?.friendName ?? "friend")?",
            isPresented: $confirmRemove
        ) {
            Button("Remove", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They'll stop receiving nudges from you, and your nudge history with them will be deleted.")
        }
        // `initial: true` covers a friend that was already gone when the screen opened.
        .onChange(of: viewModel.content, initial: true) { _, content in
            guard content == .gone else { return }
            showRename = false
            confirmRemove = false
            onGone()
        }
    }

    // MARK: - Subviews

    private func header(_ friend: Friend) -> some View {
        VStack(spacing: 4) {
            Text(friend.friendName)
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
            Text(friend.friendPhoneNumber)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.content {
        case .history:
            if let history = viewModel.historyViewModel {
                NudgeHistoryContent(viewModel: history)
            }
        case .awaitingConsent(let friend):
            awaitingConsent(friend)
        case .gone:
            Color.clear
        }
    }

    private func awaitingConsent(_ friend: Friend) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "hourglass")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Awaiting consent")
                .font(.headline)
            Text("\(friend.friendName) hasn't replied YES yet. Nudges start once they accept.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }

    private var removeSection: some View {
        VStack(spacing: 8) {
            if let removeError = viewModel.removeError {
                Text(removeError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button(role: .destructive) {
                confirmRemove = true
            } label: {
                Text("Remove Friend")
                    .fontWeight(.semibold)
                    .replacedByLoadingIndicator(while: viewModel.isRemoving)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.12))
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(viewModel.isRemoving)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

extension FriendDetailView {
    // MARK: - Remove

    private func remove() {
        Task { await viewModel.remove() }
    }
}

// MARK: - RenameFriendSheet

/// Edits a friend's display name. The phone number isn't editable: consent is tied to it.
struct RenameFriendSheet: View {
    var onCompleted: () -> Void

    @StateObject private var model: RenameFriendModel
    @FocusState private var nameFocused: Bool

    init(
        name: String,
        onSave: @escaping (String) async throws -> Void,
        onCompleted: @escaping () -> Void
    ) {
        self.onCompleted = onCompleted
        _model = StateObject(wrappedValue: RenameFriendModel(name: name, onSave: onSave))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("Name").font(.headline)
                TextField("Friend's name", text: $model.name)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .disabled(model.isSaving)

                if let hint = model.validationMessage {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if let error = model.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Edit Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCompleted() }
                        .disabled(model.isSaving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.isSaving {
                        NudgeLoadingIndicator(size: .small)
                    } else {
                        Button("Save", action: save)
                            .fontWeight(.semibold)
                            .disabled(!model.canSave)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(model.isSaving)
        .onAppear { nameFocused = true }
    }
}

extension RenameFriendSheet {
    // MARK: - Save

    private func save() {
        Task {
            if await model.save() {
                onCompleted()
            }
        }
    }
}

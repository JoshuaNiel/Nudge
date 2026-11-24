import Testing
import Foundation
@testable import Nudge

// Phase 5J — friend screen: every friend tappable, rename, remove.
// Covers the friend-name rule, which content the screen shows for the live friend, that a
// pending friend never gets a nudge-history view model (so no realtime nudge channel), live
// pending → accepted / blocked / missing transitions, rename, and remove. The friend screen
// reads the friend from the shared `SocialViewModel` (the Friends list's live state).

// MARK: - Fixtures

private let ownerId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

@MainActor
private func makeFriend(
    id: Int,
    name: String? = nil,
    status: FriendStatus = .pending,
    invitedOffset: TimeInterval = 0
) -> Friend {
    Friend(
        id: id,
        userId: ownerId,
        friendName: name ?? "Friend \(id)",
        friendPhoneNumber: "+1801555\(String(format: "%04d", id))",
        status: status,
        invitationTimestamp: Date(timeIntervalSince1970: 1_800_000_000 + invitedOffset)
    )
}

/// Polls `condition` until it holds or `timeout` elapses. Returns whether it held.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

// MARK: - Mocks

private struct TestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class MockFriendScreenService: FriendServiceProtocol {
    /// Results returned by successive `fetchFriends` calls; the last one repeats.
    var friendsResults: [Result<[Friend], Error>] = [.success([])]
    var renameResult: Result<Void, Error> = .success(())
    var deleteResult: Result<Void, Error> = .success(())
    private(set) var fetchFriendsCallCount = 0
    private(set) var renames: [(id: Int, name: String)] = []
    private(set) var deletedIds: [Int] = []

    func fetchFriends(userId: UUID) async throws -> [Friend] {
        let index = min(fetchFriendsCallCount, friendsResults.count - 1)
        fetchFriendsCallCount += 1
        return try friendsResults[index].get()
    }

    func addFriend(userId: UUID, name: String, phoneNumber: String) async throws {}

    func deleteFriend(id: Int) async throws {
        deletedIds.append(id)
        try deleteResult.get()
    }

    func updateFriendName(id: Int, name: String) async throws {
        renames.append((id, name))
        try renameResult.get()
    }

    func fetchNudgeHistory(friendId: Int) async throws -> [Nudge] { [] }
    func fetchFriendId(forNudgeId nudgeId: Int) async throws -> Int? { nil }
}

private final class MockScreenNudgeRealtimeService: NudgeRealtimeServiceProtocol {
    private(set) var requestedFriendIds: [Int] = []

    func changes(friendId: Int) -> AsyncStream<NudgeChange> {
        requestedFriendIds.append(friendId)
        let (stream, continuation) = AsyncStream<NudgeChange>.makeStream()
        continuation.finish()
        return stream
    }
}

/// Wires a `SocialViewModel` (the live list) and a `FriendDetailViewModel` for one friend,
/// recording every nudge-history view model the screen creates.
@MainActor
private final class FriendScreenHarness {
    let service = MockFriendScreenService()
    let friendRealtime = MockFriendRealtimeService()
    let nudgeRealtime = MockScreenNudgeRealtimeService()
    let social: SocialViewModel
    private(set) var createdHistoryFriendIds: [Int] = []

    init(friends: [Friend]) {
        service.friendsResults = [.success(friends)]
        social = SocialViewModel(friendService: service, realtimeService: friendRealtime)
    }

    func makeDetail(friendId: Int) -> FriendDetailViewModel {
        FriendDetailViewModel(friendId: friendId, socialViewModel: social) { [self] id in
            createdHistoryFriendIds.append(id)
            return NudgeHistoryViewModel(friendId: id, friendService: service, realtimeService: nudgeRealtime)
        }
    }
}

// MARK: - Friend name rule

@Suite("Friend name validation")
@MainActor
struct FriendNameValidationTests {

    @Test func blankIsInvalid() {
        #expect("".isValidFriendName == false)
        #expect("".friendNameValidationError == "Name can't be empty.")
    }

    @Test func whitespaceOnlyIsInvalid() {
        #expect("   \t\n ".isValidFriendName == false)
        #expect("   \t\n ".friendNameValidationError == "Name can't be empty.")
    }

    @Test func hundredCharactersIsValid() {
        let name = String(repeating: "a", count: 100)
        #expect(name.isValidFriendName)
        #expect(name.friendNameValidationError == nil)
    }

    @Test func hundredAndOneCharactersIsInvalid() {
        let name = String(repeating: "a", count: 101)
        #expect(name.isValidFriendName == false)
        #expect(name.friendNameValidationError == "Name must be 100 characters or fewer.")
    }

    @Test func surroundingWhitespaceIsTrimmedBeforeTheLengthCheck() {
        let name = "  " + String(repeating: "a", count: 100) + " \n"
        #expect(name.isValidFriendName)
        #expect(name.trimmedFriendName == String(repeating: "a", count: 100))
    }

    @Test func trimmingKeepsInnerSpaces() {
        #expect("  Alice B.  ".trimmedFriendName == "Alice B.")
    }

    @Test func maxLengthMatchesTheColumn() {
        #expect(String.friendNameMaxLength == 100)
    }
}

// MARK: - Screen content

@Suite("FriendScreenContent")
@MainActor
struct FriendScreenContentTests {

    @Test func pendingFriendAwaitsConsent() {
        let friend = makeFriend(id: 1, status: .pending)
        #expect(FriendScreenContent.resolve(friendId: 1, in: [friend]) == .awaitingConsent(friend))
    }

    @Test func acceptedFriendShowsHistory() {
        let friend = makeFriend(id: 1, status: .accepted)
        #expect(FriendScreenContent.resolve(friendId: 1, in: [friend]) == .history(friend))
    }

    @Test func blockedFriendIsGone() {
        let friend = makeFriend(id: 1, status: .blocked)
        #expect(FriendScreenContent.resolve(friendId: 1, in: [friend]) == .gone)
    }

    @Test func missingFriendIsGone() {
        #expect(FriendScreenContent.resolve(friendId: 1, in: [makeFriend(id: 2)]) == .gone)
    }

    @Test func friendAccessorReturnsTheShownFriend() {
        let friend = makeFriend(id: 1, status: .accepted)
        #expect(FriendScreenContent.history(friend).friend == friend)
        #expect(FriendScreenContent.awaitingConsent(friend).friend == friend)
        #expect(FriendScreenContent.gone.friend == nil)
    }
}

// MARK: - FriendDetailViewModel — live state

@Suite("FriendDetailViewModel live state")
@MainActor
struct FriendDetailLiveStateTests {

    @Test func pendingScreenOpensNoNudgeChannel() async {
        let harness = FriendScreenHarness(friends: [makeFriend(id: 1, status: .pending)])
        await harness.social.load(userId: ownerId)

        let detail = harness.makeDetail(friendId: 1)

        #expect(detail.content == .awaitingConsent(makeFriend(id: 1, status: .pending)))
        #expect(detail.historyViewModel == nil)
        #expect(harness.createdHistoryFriendIds.isEmpty)
        #expect(harness.nudgeRealtime.requestedFriendIds.isEmpty)
    }

    @Test func acceptedScreenShowsHistoryForThatFriend() async {
        // E.g. opened from a reply push deep link.
        let harness = FriendScreenHarness(friends: [makeFriend(id: 1, status: .accepted)])
        await harness.social.load(userId: ownerId)

        let detail = harness.makeDetail(friendId: 1)

        #expect(detail.content == .history(makeFriend(id: 1, status: .accepted)))
        #expect(detail.historyViewModel?.friendId == 1)
        #expect(harness.createdHistoryFriendIds == [1])
    }

    @Test func pendingToAcceptedSwitchesToHistoryLive() async {
        let harness = FriendScreenHarness(friends: [makeFriend(id: 1, status: .pending)])
        let task = Task { await harness.social.start(userId: ownerId) }
        #expect(await waitUntil { harness.friendRealtime.continuation != nil && harness.social.friends.count == 1 })
        let detail = harness.makeDetail(friendId: 1)
        #expect(detail.historyViewModel == nil)

        harness.friendRealtime.continuation?.yield(.updated(makeFriend(id: 1, status: .accepted)))

        #expect(await waitUntil { detail.content == .history(makeFriend(id: 1, status: .accepted)) })
        #expect(detail.historyViewModel?.friendId == 1)
        #expect(harness.createdHistoryFriendIds == [1])

        // The history (and its nudge channel) only starts once the history is shown.
        await detail.historyViewModel?.start()
        #expect(harness.nudgeRealtime.requestedFriendIds == [1])

        harness.friendRealtime.continuation?.finish()
        await task.value
    }

    @Test func historyViewModelIsCreatedOnlyOnce() async {
        let harness = FriendScreenHarness(friends: [makeFriend(id: 1, name: "Alice", status: .accepted)])
        let task = Task { await harness.social.start(userId: ownerId) }
        #expect(await waitUntil { harness.friendRealtime.continuation != nil && harness.social.friends.count == 1 })
        let detail = harness.makeDetail(friendId: 1)
        let history = detail.historyViewModel

        harness.friendRealtime.continuation?.yield(.updated(makeFriend(id: 1, name: "Alice B.", status: .accepted)))

        #expect(await waitUntil { detail.content.friend?.friendName == "Alice B." })
        #expect(detail.historyViewModel === history)
        #expect(harness.createdHistoryFriendIds == [1])

        harness.friendRealtime.continuation?.finish()
        await task.value
    }

    @Test func blockedUpdatePopsTheScreen() async {
        let harness = FriendScreenHarness(friends: [makeFriend(id: 1, status: .accepted)])
        let task = Task { await harness.social.start(userId: ownerId) }
        #expect(await waitUntil { harness.friendRealtime.continuation != nil && harness.social.friends.count == 1 })
        let detail = harness.makeDetail(friendId: 1)

        harness.friendRealtime.continuation?.yield(.updated(makeFriend(id: 1, status: .blocked)))

        #expect(await waitUntil { detail.content == .gone })

        harness.friendRealtime.continuation?.finish()
        await task.value
    }

    @Test func refreshWithoutTheFriendPopsTheScreen() async {
        // Deleted elsewhere: the next fetch no longer returns the row.
        let harness = FriendScreenHarness(friends: [])
        harness.service.friendsResults = [
            .success([makeFriend(id: 1, status: .accepted), makeFriend(id: 2, status: .accepted)]),
            .success([makeFriend(id: 2, status: .accepted)]),
        ]
        await harness.social.load(userId: ownerId)
        let detail = harness.makeDetail(friendId: 1)
        #expect(detail.content != .gone)

        await harness.social.refresh(userId: ownerId)

        #expect(detail.content == .gone)
    }

    @Test func unknownFriendIsGoneImmediately() async {
        let harness = FriendScreenHarness(friends: [makeFriend(id: 2)])
        await harness.social.load(userId: ownerId)

        let detail = harness.makeDetail(friendId: 1)

        #expect(detail.content == .gone)
        #expect(detail.historyViewModel == nil)
    }
}

// MARK: - Rename

@Suite("Friend rename")
@MainActor
struct FriendRenameTests {

    @Test func saveSendsTrimmedNameAndUpdatesListAndScreen() async {
        let harness = FriendScreenHarness(friends: [makeFriend(id: 1, name: "Alice", status: .accepted)])
        await harness.social.load(userId: ownerId)
        let detail = harness.makeDetail(friendId: 1)
        let model = RenameFriendModel(name: "Alice") { try await detail.rename(to: $0) }
        model.name = "  Alice B.  "

        let saved = await model.save()

        #expect(saved)
        #expect(harness.service.renames.map(\.id) == [1])
        #expect(harness.service.renames.map(\.name) == ["Alice B."])
        #expect(harness.social.friends.first?.friendName == "Alice B.")
        #expect(detail.content.friend?.friendName == "Alice B.")
        #expect(model.error == nil)
        #expect(model.isSaving == false)
    }

    @Test func realtimeEchoOfTheRenameIsDeduped() async {
        let harness = FriendScreenHarness(friends: [makeFriend(id: 1, name: "Alice", status: .accepted)])
        let task = Task { await harness.social.start(userId: ownerId) }
        #expect(await waitUntil { harness.friendRealtime.continuation != nil && harness.social.friends.count == 1 })
        let detail = harness.makeDetail(friendId: 1)
        try? await detail.rename(to: "Alice B.")
        let afterRename = harness.social.friends

        harness.friendRealtime.continuation?.yield(.updated(makeFriend(id: 1, name: "Alice B.", status: .accepted)))
        harness.friendRealtime.continuation?.yield(.inserted(makeFriend(id: 3, invitedOffset: 30)))  // marker
        #expect(await waitUntil { harness.social.friends.count == 2 })

        #expect(harness.social.friends.filter { $0.id == 1 } == afterRename)

        harness.friendRealtime.continuation?.finish()
        await task.value
    }

    @Test func failureKeepsTheEditAndShowsTheError() async {
        let harness = FriendScreenHarness(friends: [makeFriend(id: 1, name: "Alice", status: .accepted)])
        harness.service.renameResult = .failure(TestError(message: "Rename failed"))
        await harness.social.load(userId: ownerId)
        let detail = harness.makeDetail(friendId: 1)
        let model = RenameFriendModel(name: "Alice") { try await detail.rename(to: $0) }
        model.name = "Alice B."

        let saved = await model.save()

        #expect(saved == false)
        #expect(model.name == "Alice B.")
        #expect(model.error == "Rename failed")
        #expect(model.isSaving == false)
        #expect(harness.social.friends.first?.friendName == "Alice")
        #expect(detail.content.friend?.friendName == "Alice")
        #expect(harness.social.error == nil)
    }

    @Test func retryAfterFailureClearsTheError() async {
        let harness = FriendScreenHarness(friends: [makeFriend(id: 1, name: "Alice", status: .accepted)])
        harness.service.renameResult = .failure(TestError(message: "Rename failed"))
        await harness.social.load(userId: ownerId)
        let detail = harness.makeDetail(friendId: 1)
        let model = RenameFriendModel(name: "Alice") { try await detail.rename(to: $0) }
        model.name = "Alice B."
        _ = await model.save()

        harness.service.renameResult = .success(())
        let saved = await model.save()

        #expect(saved)
        #expect(model.error == nil)
        #expect(harness.social.friends.first?.friendName == "Alice B.")
    }

    @Test func invalidNameCannotBeSaved() async {
        let harness = FriendScreenHarness(friends: [makeFriend(id: 1, name: "Alice", status: .accepted)])
        await harness.social.load(userId: ownerId)
        let detail = harness.makeDetail(friendId: 1)
        let model = RenameFriendModel(name: "Alice") { try await detail.rename(to: $0) }

        model.name = "   "
        #expect(model.canSave == false)
        #expect(model.validationMessage == "Name can't be empty.")

        let saved = await model.save()

        #expect(saved == false)
        #expect(harness.service.renames.isEmpty)
        #expect(harness.social.friends.first?.friendName == "Alice")
    }

    @Test func prefilledNameCanBeSaved() {
        let model = RenameFriendModel(name: "Alice") { _ in }
        #expect(model.name == "Alice")
        #expect(model.canSave)
        #expect(model.validationMessage == nil)
    }

    @Test func tooLongNameShowsHint() {
        let model = RenameFriendModel(name: "Alice") { _ in }
        model.name = String(repeating: "a", count: 101)
        #expect(model.canSave == false)
        #expect(model.validationMessage == "Name must be 100 characters or fewer.")
    }
}

// MARK: - Remove

@Suite("Friend remove")
@MainActor
struct FriendRemoveTests {

    @Test func successRemovesFromListAndPops() async {
        let harness = FriendScreenHarness(friends: [
            makeFriend(id: 2, status: .accepted, invitedOffset: 20),
            makeFriend(id: 1, status: .pending, invitedOffset: 10),
        ])
        await harness.social.load(userId: ownerId)
        let detail = harness.makeDetail(friendId: 1)

        await detail.remove()

        #expect(harness.service.deletedIds == [1])
        #expect(harness.social.friends.map(\.id) == [2])
        #expect(detail.content == .gone)
        #expect(detail.removeError == nil)
        #expect(detail.isRemoving == false)
    }

    @Test func failureKeepsTheFriendAndShowsTheError() async {
        let harness = FriendScreenHarness(friends: [makeFriend(id: 1, status: .accepted)])
        harness.service.deleteResult = .failure(TestError(message: "Remove failed"))
        await harness.social.load(userId: ownerId)
        let detail = harness.makeDetail(friendId: 1)

        await detail.remove()

        #expect(harness.social.friends.map(\.id) == [1])
        #expect(detail.content == .history(makeFriend(id: 1, status: .accepted)))
        #expect(detail.removeError == "Remove failed")
        #expect(detail.isRemoving == false)
        // The list itself is not replaced by an error screen.
        #expect(harness.social.error == nil)
    }

    @Test func retryAfterFailureClearsTheError() async {
        let harness = FriendScreenHarness(friends: [makeFriend(id: 1, status: .accepted)])
        harness.service.deleteResult = .failure(TestError(message: "Remove failed"))
        await harness.social.load(userId: ownerId)
        let detail = harness.makeDetail(friendId: 1)
        await detail.remove()

        harness.service.deleteResult = .success(())
        await detail.remove()

        #expect(detail.removeError == nil)
        #expect(detail.content == .gone)
    }

    @Test func swipeToDeleteStillRemovesFromTheList() async {
        // The list's swipe-to-delete path shares the same removal.
        let harness = FriendScreenHarness(friends: [makeFriend(id: 1, status: .accepted)])
        await harness.social.load(userId: ownerId)

        await harness.social.deleteFriend(makeFriend(id: 1, status: .accepted))

        #expect(harness.service.deletedIds == [1])
        #expect(harness.social.friends.isEmpty)
    }
}

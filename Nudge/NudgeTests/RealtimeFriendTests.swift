import Testing
import Foundation
import Supabase
@testable import Nudge

// Phase 5I — live Friends list.
// Covers the pure merge rules, decoding a Realtime postgres_changes record into `Friend`,
// and `SocialViewModel` driven by a mock FriendService + a mock realtime stream.
// The real `FriendRealtimeService` is a thin wrapper around the shared Postgres Changes feed.

// MARK: - Fixtures

private let ownerId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let otherUserId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

@MainActor
private func makeFriend(
    id: Int,
    userId: UUID = ownerId,
    name: String? = nil,
    status: FriendStatus = .pending,
    invitedOffset: TimeInterval = 0
) -> Friend {
    Friend(
        id: id,
        userId: userId,
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

// MARK: - Merge rules

@Suite("FriendListMerge")
@MainActor
struct FriendListMergeTests {

    @Test func insertOfNewNewerFriendGoesToTheTop() {
        let list = [makeFriend(id: 2, invitedOffset: 20), makeFriend(id: 1, invitedOffset: 10)]
        let new = makeFriend(id: 3, invitedOffset: 30)

        let result = FriendListMerge.applying(.inserted(new), to: list, userId: ownerId)

        #expect(result.map(\.id) == [3, 2, 1])
    }

    @Test func insertOfOlderFriendLandsInSortedPosition() {
        let list = [makeFriend(id: 3, invitedOffset: 30), makeFriend(id: 1, invitedOffset: 10)]
        let new = makeFriend(id: 2, invitedOffset: 20)

        let result = FriendListMerge.applying(.inserted(new), to: list, userId: ownerId)

        #expect(result.map(\.id) == [3, 2, 1])
    }

    @Test func insertIntoEmptyListAddsIt() {
        let new = makeFriend(id: 1)

        #expect(FriendListMerge.applying(.inserted(new), to: [], userId: ownerId) == [new])
    }

    @Test func duplicateInsertIsANoOpAndKeepsTheExistingRow() {
        // The held row may already be newer (e.g. a refetch returned it as accepted).
        let existing = makeFriend(id: 1, status: .accepted)
        let staleInsert = makeFriend(id: 1, status: .pending)

        let result = FriendListMerge.applying(.inserted(staleInsert), to: [existing], userId: ownerId)

        #expect(result == [existing])
    }

    @Test func updatePendingToAcceptedReplacesTheRow() {
        let list = [makeFriend(id: 2, invitedOffset: 20), makeFriend(id: 1, status: .pending, invitedOffset: 10)]
        let accepted = makeFriend(id: 1, status: .accepted, invitedOffset: 10)

        let result = FriendListMerge.applying(.updated(accepted), to: list, userId: ownerId)

        #expect(result.map(\.id) == [2, 1])
        #expect(result[1].status == .accepted)
        #expect(result.filter { $0.id == 1 }.count == 1)
    }

    @Test func renameIsShown() {
        let list = [makeFriend(id: 1, name: "Alice", status: .accepted)]
        let renamed = makeFriend(id: 1, name: "Alice B.", status: .accepted)

        let result = FriendListMerge.applying(.updated(renamed), to: list, userId: ownerId)

        #expect(result.map(\.friendName) == ["Alice B."])
    }

    @Test func updateToBlockedRemovesTheRow() {
        let list = [makeFriend(id: 2, invitedOffset: 20), makeFriend(id: 1, status: .accepted, invitedOffset: 10)]
        let blocked = makeFriend(id: 1, status: .blocked, invitedOffset: 10)

        let result = FriendListMerge.applying(.updated(blocked), to: list, userId: ownerId)

        #expect(result.map(\.id) == [2])
    }

    @Test func blockedUpdateForUnknownIdIsANoOp() {
        let list = [makeFriend(id: 1)]

        let result = FriendListMerge.applying(.updated(makeFriend(id: 9, status: .blocked)), to: list, userId: ownerId)

        #expect(result == list)
    }

    @Test func blockedInsertIsNotShown() {
        let result = FriendListMerge.applying(.inserted(makeFriend(id: 1, status: .blocked)), to: [], userId: ownerId)

        #expect(result.isEmpty)
    }

    @Test func updateForUnknownIdIsInserted() {
        // We missed the INSERT (disconnected / before load) — the UPDATE is the freshest state.
        let list = [makeFriend(id: 1, invitedOffset: 10)]
        let updated = makeFriend(id: 2, status: .accepted, invitedOffset: 20)

        let result = FriendListMerge.applying(.updated(updated), to: list, userId: ownerId)

        #expect(result.map(\.id) == [2, 1])
        #expect(result[0] == updated)
    }

    @Test func insertForAnotherUserIsIgnored() {
        let list = [makeFriend(id: 1)]
        let foreign = makeFriend(id: 2, userId: otherUserId, invitedOffset: 50)

        #expect(FriendListMerge.applying(.inserted(foreign), to: list, userId: ownerId) == list)
    }

    @Test func updateForAnotherUserIsIgnored() {
        let list = [makeFriend(id: 1)]
        let foreign = makeFriend(id: 1, userId: otherUserId, status: .accepted)

        #expect(FriendListMerge.applying(.updated(foreign), to: list, userId: ownerId) == list)
    }

    @Test func subscribedSignalLeavesListUnchanged() {
        let list = [makeFriend(id: 2, invitedOffset: 20), makeFriend(id: 1, invitedOffset: 10)]

        #expect(FriendListMerge.applying(.subscribed, to: list, userId: ownerId) == list)
    }

    @Test func sortedIsNewestInvitationFirstWithIdTieBreak() {
        let list = [
            makeFriend(id: 1, invitedOffset: 10),
            makeFriend(id: 4, invitedOffset: 20),
            makeFriend(id: 3, invitedOffset: 30),
            makeFriend(id: 5, invitedOffset: 20),
        ]

        #expect(FriendListMerge.sorted(list).map(\.id) == [3, 5, 4, 1])
    }
}

// MARK: - Realtime record decoding

@Suite("Realtime friend record decoding")
@MainActor
struct RealtimeFriendDecodingTests {

    /// Parses JSON into the `JSONObject` shape Realtime hands us in `InsertAction.record`.
    private func record(_ json: String) throws -> JSONObject {
        try JSONDecoder().decode(JSONObject.self, from: Data(json.utf8))
    }

    @Test func decodesInsertRecord() throws {
        // Realistic walrus payload: bigint as number, lowercase uuid, timestamptz with microseconds.
        let json = """
        {
          "id": 42,
          "user_id": "11111111-1111-1111-1111-111111111111",
          "friend_name": "Alice",
          "friend_phone_number": "+18015551234",
          "status": "pending",
          "invitation_timestamp": "2026-11-14T17:03:21.578839+00:00"
        }
        """

        let friend = try FriendRealtimeService.decodeFriend(from: record(json))

        #expect(friend.id == 42)
        #expect(friend.userId == ownerId)
        #expect(friend.friendName == "Alice")
        #expect(friend.friendPhoneNumber == "+18015551234")
        #expect(friend.status == .pending)
        let expected = Date(timeIntervalSince1970: 1_794_675_801.578)
        #expect(abs(friend.invitationTimestamp.timeIntervalSince(expected)) < 0.01)
    }

    @Test func decodesAcceptedAndBlockedStatuses() throws {
        let accepted = """
        {"id": 1, "user_id": "11111111-1111-1111-1111-111111111111", "friend_name": "A",
         "friend_phone_number": "+18015550001", "status": "accepted",
         "invitation_timestamp": "2026-11-14T17:03:21+00:00"}
        """
        let blocked = accepted.replacingOccurrences(of: "\"accepted\"", with: "\"blocked\"")

        #expect(try FriendRealtimeService.decodeFriend(from: record(accepted)).status == .accepted)
        #expect(try FriendRealtimeService.decodeFriend(from: record(blocked)).status == .blocked)
    }

    @Test func recordMissingRequiredColumnThrows() throws {
        let json = """
        {"id": 1, "friend_name": "A", "status": "pending", "invitation_timestamp": "2026-11-14T17:03:21+00:00"}
        """
        let rec = try record(json)

        #expect(throws: (any Error).self) {
            _ = try FriendRealtimeService.decodeFriend(from: rec)
        }
    }
}

// MARK: - Mocks

private struct TestError: LocalizedError {
    var errorDescription: String? { "Friends unavailable" }
}

private final class MockListFriendService: FriendServiceProtocol {
    /// Results returned by successive `fetchFriends` calls; the last one repeats.
    var friendsResults: [Result<[Friend], Error>] = [.success([])]
    private(set) var fetchFriendsCallCount = 0
    private(set) var requestedUserIds: [UUID] = []
    private(set) var deletedIds: [Int] = []

    func fetchFriends(userId: UUID) async throws -> [Friend] {
        let index = min(fetchFriendsCallCount, friendsResults.count - 1)
        fetchFriendsCallCount += 1
        requestedUserIds.append(userId)
        return try friendsResults[index].get()
    }

    func addFriend(userId: UUID, name: String, phoneNumber: String) async throws {}
    func deleteFriend(id: Int) async throws { deletedIds.append(id) }
    func updateFriendName(id: Int, name: String) async throws {}
    func fetchNudgeHistory(friendId: Int) async throws -> [Nudge] { [] }
    func fetchFriendId(forNudgeId nudgeId: Int) async throws -> Int? { nil }
}

/// Realtime mock shared with the other Social test files (which don't exercise the stream).
final class MockFriendRealtimeService: FriendRealtimeServiceProtocol {
    private(set) var requestedUserIds: [UUID] = []
    private(set) var continuation: AsyncStream<FriendChange>.Continuation?
    private(set) var terminationCount = 0

    func changes(userId: UUID) -> AsyncStream<FriendChange> {
        requestedUserIds.append(userId)
        let (stream, continuation) = AsyncStream<FriendChange>.makeStream()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.terminationCount += 1 }
        }
        self.continuation = continuation
        return stream
    }
}

/// Records what `start(userId:onInitialFetch:)`'s callback saw (a class so the test task can mutate it).
private final class CallbackRecorder {
    var friendCounts: [Int] = []
}

// MARK: - SocialViewModel — loading

@Suite("SocialViewModel live list loading")
@MainActor
struct SocialViewModelLiveLoadTests {

    private func makeViewModel(_ service: MockListFriendService) -> SocialViewModel {
        SocialViewModel(friendService: service, realtimeService: MockFriendRealtimeService())
    }

    @Test func loadPublishesSortedFriendsForTheUser() async {
        let service = MockListFriendService()
        service.friendsResults = [.success([makeFriend(id: 1, invitedOffset: 10), makeFriend(id: 2, invitedOffset: 20)])]
        let vm = makeViewModel(service)

        await vm.load(userId: ownerId)

        #expect(vm.friends.map(\.id) == [2, 1])
        #expect(vm.isLoading == false)
        #expect(vm.error == nil)
        #expect(service.requestedUserIds == [ownerId])
    }

    @Test func loadFailureSetsError() async {
        let service = MockListFriendService()
        service.friendsResults = [.failure(TestError())]
        let vm = makeViewModel(service)

        await vm.load(userId: ownerId)

        #expect(vm.error == "Friends unavailable")
        #expect(vm.friends.isEmpty)
        #expect(vm.isLoading == false)
    }

    @Test func refreshFailureKeepsExistingListWithoutError() async {
        let service = MockListFriendService()
        service.friendsResults = [.success([makeFriend(id: 1)]), .failure(TestError())]
        let vm = makeViewModel(service)
        await vm.load(userId: ownerId)

        await vm.refresh(userId: ownerId)

        #expect(vm.friends.map(\.id) == [1])
        #expect(vm.error == nil)
        #expect(vm.isLoading == false)
    }

    @Test func refreshFailureWithNothingToShowSetsError() async {
        let service = MockListFriendService()
        service.friendsResults = [.failure(TestError())]
        let vm = makeViewModel(service)

        await vm.refresh(userId: ownerId)

        #expect(vm.error == "Friends unavailable")
    }

    @Test func refreshFromErrorStateRetriesAndClearsError() async {
        // Pull-to-refresh on the error state.
        let service = MockListFriendService()
        service.friendsResults = [.failure(TestError()), .success([makeFriend(id: 1)])]
        let vm = makeViewModel(service)
        await vm.load(userId: ownerId)

        await vm.refresh(userId: ownerId)

        #expect(vm.error == nil)
        #expect(vm.friends.map(\.id) == [1])
    }

    @Test func refreshReplacesListWithLatestServerState() async {
        let service = MockListFriendService()
        service.friendsResults = [
            .success([makeFriend(id: 1, status: .pending)]),
            .success([makeFriend(id: 1, status: .accepted)]),
        ]
        let vm = makeViewModel(service)
        await vm.load(userId: ownerId)

        await vm.refresh(userId: ownerId)

        #expect(vm.friends.first?.status == .accepted)
    }
}

// MARK: - SocialViewModel — realtime

@Suite("SocialViewModel live list realtime")
@MainActor
struct SocialViewModelRealtimeTests {

    @Test func startLoadsThenAppliesStreamedInsertAndAcceptance() async {
        let service = MockListFriendService()
        service.friendsResults = [.success([makeFriend(id: 1, status: .pending, invitedOffset: 10)])]
        let realtime = MockFriendRealtimeService()
        let vm = SocialViewModel(friendService: service, realtimeService: realtime)

        let task = Task { await vm.start(userId: ownerId) }
        #expect(await waitUntil { realtime.continuation != nil && vm.friends.count == 1 && !vm.isLoading })
        #expect(realtime.requestedUserIds == [ownerId])
        #expect(vm.isObserving)

        // SQL insert appears live.
        realtime.continuation?.yield(.inserted(makeFriend(id: 2, invitedOffset: 20)))
        #expect(await waitUntil { vm.friends.map(\.id) == [2, 1] })

        // pending → accepted moves the row between sections (same id, new status).
        realtime.continuation?.yield(.updated(makeFriend(id: 1, status: .accepted, invitedOffset: 10)))
        #expect(await waitUntil { vm.friends.first { $0.id == 1 }?.status == .accepted })
        #expect(vm.friends.map(\.id) == [2, 1])

        realtime.continuation?.finish()
        await task.value
    }

    @Test func blockedUpdateRemovesAndRenameShows() async {
        let service = MockListFriendService()
        service.friendsResults = [.success([
            makeFriend(id: 2, name: "Bob", status: .accepted, invitedOffset: 20),
            makeFriend(id: 1, name: "Alice", status: .accepted, invitedOffset: 10),
        ])]
        let realtime = MockFriendRealtimeService()
        let vm = SocialViewModel(friendService: service, realtimeService: realtime)

        let task = Task { await vm.start(userId: ownerId) }
        #expect(await waitUntil { realtime.continuation != nil && vm.friends.count == 2 && !vm.isLoading })

        realtime.continuation?.yield(.updated(makeFriend(id: 2, name: "Bob", status: .blocked, invitedOffset: 20)))
        #expect(await waitUntil { vm.friends.map(\.id) == [1] })

        realtime.continuation?.yield(.updated(makeFriend(id: 1, name: "Alice B.", status: .accepted, invitedOffset: 10)))
        #expect(await waitUntil { vm.friends.first?.friendName == "Alice B." })

        realtime.continuation?.finish()
        await task.value
    }

    @Test func duplicateInsertAfterLoadDoesNotDuplicate() async {
        let service = MockListFriendService()
        service.friendsResults = [.success([makeFriend(id: 1, status: .accepted)])]
        let realtime = MockFriendRealtimeService()
        let vm = SocialViewModel(friendService: service, realtimeService: realtime)

        let task = Task { await vm.start(userId: ownerId) }
        #expect(await waitUntil { realtime.continuation != nil && vm.friends.count == 1 && !vm.isLoading })

        realtime.continuation?.yield(.inserted(makeFriend(id: 1, status: .pending)))
        realtime.continuation?.yield(.inserted(makeFriend(id: 3, invitedOffset: 30)))  // marker
        #expect(await waitUntil { vm.friends.count == 2 })
        #expect(vm.friends.map(\.id) == [3, 1])
        #expect(vm.friends.last?.status == .accepted)

        realtime.continuation?.finish()
        await task.value
    }

    @Test func eventsForOtherUsersAreIgnored() async {
        let service = MockListFriendService()
        service.friendsResults = [.success([makeFriend(id: 1)])]
        let realtime = MockFriendRealtimeService()
        let vm = SocialViewModel(friendService: service, realtimeService: realtime)

        let task = Task { await vm.start(userId: ownerId) }
        #expect(await waitUntil { realtime.continuation != nil && vm.friends.count == 1 && !vm.isLoading })

        realtime.continuation?.yield(.inserted(makeFriend(id: 9, userId: otherUserId, invitedOffset: 90)))
        realtime.continuation?.yield(.inserted(makeFriend(id: 3, invitedOffset: 30)))  // marker
        #expect(await waitUntil { vm.friends.count == 2 })
        #expect(vm.friends.map(\.id) == [3, 1])

        realtime.continuation?.finish()
        await task.value
    }

    @Test func subscribedSignalTriggersRefetch() async {
        // Every (re)connect refetches — covers changes (incl. deletes) missed while not listening.
        let service = MockListFriendService()
        service.friendsResults = [
            .success([makeFriend(id: 1)]),
            .success([makeFriend(id: 2, invitedOffset: 20), makeFriend(id: 1, status: .accepted)]),
        ]
        let realtime = MockFriendRealtimeService()
        let vm = SocialViewModel(friendService: service, realtimeService: realtime)

        let task = Task { await vm.start(userId: ownerId) }
        #expect(await waitUntil { realtime.continuation != nil && service.fetchFriendsCallCount == 1 && !vm.isLoading })

        realtime.continuation?.yield(.subscribed)
        #expect(await waitUntil { service.fetchFriendsCallCount == 2 })
        #expect(await waitUntil { vm.friends.map(\.id) == [2, 1] })
        #expect(vm.friends.last?.status == .accepted)

        realtime.continuation?.finish()
        await task.value
    }

    @Test func initialFetchCallbackRunsOnceAfterTheFirstFetch() async {
        let service = MockListFriendService()
        service.friendsResults = [.success([makeFriend(id: 1)])]
        let realtime = MockFriendRealtimeService()
        let vm = SocialViewModel(friendService: service, realtimeService: realtime)
        let recorder = CallbackRecorder()

        let task = Task {
            await vm.start(userId: ownerId) { recorder.friendCounts.append(vm.friends.count) }
        }
        #expect(await waitUntil { realtime.continuation != nil && recorder.friendCounts.count == 1 })
        #expect(recorder.friendCounts == [1])   // list already loaded when the deep link runs

        realtime.continuation?.yield(.subscribed)
        #expect(await waitUntil { service.fetchFriendsCallCount == 2 })
        #expect(recorder.friendCounts == [1])   // not re-run on refetch

        realtime.continuation?.finish()
        await task.value
    }

    @Test func streamEndingReturnsCleanlyAndKeepsList() async {
        let service = MockListFriendService()
        service.friendsResults = [.success([makeFriend(id: 1)])]
        let realtime = MockFriendRealtimeService()
        let vm = SocialViewModel(friendService: service, realtimeService: realtime)

        let task = Task { await vm.start(userId: ownerId) }
        #expect(await waitUntil { realtime.continuation != nil && vm.friends.count == 1 })

        realtime.continuation?.finish()
        await task.value

        #expect(vm.friends.map(\.id) == [1])
        #expect(vm.error == nil)
        #expect(vm.isObserving == false)
    }

    @Test func cancellingStartTerminatesTheStream() async {
        // `.task` cancels on disappear — the realtime stream (and its channel) must be torn down.
        let service = MockListFriendService()
        service.friendsResults = [.success([makeFriend(id: 1)])]
        let realtime = MockFriendRealtimeService()
        let vm = SocialViewModel(friendService: service, realtimeService: realtime)

        let task = Task { await vm.start(userId: ownerId) }
        #expect(await waitUntil { realtime.continuation != nil && vm.friends.count == 1 })

        task.cancel()
        await task.value

        #expect(await waitUntil { realtime.terminationCount == 1 })
        #expect(vm.isObserving == false)
    }

    @Test func restartingAfterDisappearOpensOneNewStreamAndRefreshesWithoutSpinner() async {
        let service = MockListFriendService()
        service.friendsResults = [.success([makeFriend(id: 1)])]
        let realtime = MockFriendRealtimeService()
        let vm = SocialViewModel(friendService: service, realtimeService: realtime)

        let first = Task { await vm.start(userId: ownerId) }
        #expect(await waitUntil { vm.friends.count == 1 })
        first.cancel()
        await first.value

        let second = Task { await vm.start(userId: ownerId) }
        #expect(await waitUntil { service.fetchFriendsCallCount == 2 && realtime.requestedUserIds.count == 2 })
        #expect(vm.friends.map(\.id) == [1])
        #expect(vm.isLoading == false)
        second.cancel()
        await second.value

        #expect(await waitUntil { realtime.terminationCount == 2 })
    }

    @Test func foregroundRefreshesOnlyWhileObserving() async {
        let service = MockListFriendService()
        service.friendsResults = [.success([makeFriend(id: 1)])]
        let realtime = MockFriendRealtimeService()
        let vm = SocialViewModel(friendService: service, realtimeService: realtime)

        // Not on screen → no fetch.
        await vm.sceneDidBecomeActive()
        #expect(service.fetchFriendsCallCount == 0)

        let task = Task { await vm.start(userId: ownerId) }
        #expect(await waitUntil { realtime.continuation != nil && service.fetchFriendsCallCount == 1 && !vm.isLoading })

        await vm.sceneDidBecomeActive()
        #expect(service.fetchFriendsCallCount == 2)

        realtime.continuation?.finish()
        await task.value

        await vm.sceneDidBecomeActive()
        #expect(service.fetchFriendsCallCount == 2)
    }

    @Test func swipeDeleteWhileObservingRemovesTheRow() async {
        let service = MockListFriendService()
        let friend = makeFriend(id: 1, status: .accepted)
        service.friendsResults = [.success([friend])]
        let realtime = MockFriendRealtimeService()
        let vm = SocialViewModel(friendService: service, realtimeService: realtime)

        let task = Task { await vm.start(userId: ownerId) }
        #expect(await waitUntil { realtime.continuation != nil && vm.friends.count == 1 && !vm.isLoading })

        await vm.deleteFriend(friend)
        #expect(vm.friends.isEmpty)
        #expect(service.deletedIds == [1])

        realtime.continuation?.finish()
        await task.value
    }
}

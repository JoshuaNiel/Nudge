import Testing
import Foundation
import Supabase
@testable import Nudge

// Phase 5H — real-time nudge status.
// Covers the pure merge rules, decoding a Realtime postgres_changes record into `Nudge`,
// and `NudgeHistoryViewModel` driven by a mock FriendService + a mock realtime stream.
// The real `NudgeRealtimeService` is a thin wrapper around the Supabase channel API.

// MARK: - Fixtures

@MainActor
private func makeNudge(
    id: Int,
    friendId: Int = 7,
    sentOffset: TimeInterval = 0,
    status: NudgeStatus = .sentToFriend,
    type: NudgeType? = nil,
    reply: String? = nil
) -> Nudge {
    Nudge(
        id: id,
        friendId: friendId,
        prompt: "Prompt \(id)",
        friendReply: reply,
        type: type,
        status: status,
        sentTimestamp: Date(timeIntervalSince1970: 1_800_000_000 + sentOffset)
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

@Suite("NudgeHistoryMerge")
@MainActor
struct NudgeHistoryMergeTests {

    private let friendId = 7

    @Test func insertOfNewNewerNudgeGoesToTheTop() {
        let list = [makeNudge(id: 2, sentOffset: 20), makeNudge(id: 1, sentOffset: 10)]
        let new = makeNudge(id: 3, sentOffset: 30)

        let result = NudgeHistoryMerge.applying(.inserted(new), to: list, friendId: friendId)

        #expect(result.map(\.id) == [3, 2, 1])
    }

    @Test func insertOfOlderNudgeLandsInSortedPosition() {
        let list = [makeNudge(id: 3, sentOffset: 30), makeNudge(id: 1, sentOffset: 10)]
        let new = makeNudge(id: 2, sentOffset: 20)

        let result = NudgeHistoryMerge.applying(.inserted(new), to: list, friendId: friendId)

        #expect(result.map(\.id) == [3, 2, 1])
    }

    @Test func insertIntoEmptyListAddsIt() {
        let new = makeNudge(id: 1)

        let result = NudgeHistoryMerge.applying(.inserted(new), to: [], friendId: friendId)

        #expect(result == [new])
    }

    @Test func duplicateInsertIsANoOpAndKeepsTheExistingRow() {
        // The existing row may already be newer (e.g. replied) than a late/replayed INSERT.
        let existing = makeNudge(id: 1, status: .replied, type: .custom, reply: "hi")
        let staleInsert = makeNudge(id: 1, status: .sentToFriend)

        let result = NudgeHistoryMerge.applying(.inserted(staleInsert), to: [existing], friendId: friendId)

        #expect(result == [existing])
    }

    @Test func updateReplacesExistingRowById() {
        let list = [makeNudge(id: 2, sentOffset: 20), makeNudge(id: 1, sentOffset: 10)]
        let updated = makeNudge(id: 1, sentOffset: 10, status: .replied, type: .encouragement, reply: "You got this")

        let result = NudgeHistoryMerge.applying(.updated(updated), to: list, friendId: friendId)

        #expect(result.map(\.id) == [2, 1])
        #expect(result[1] == updated)
        #expect(result[1].status == .replied)
        #expect(result[1].type == .encouragement)
        #expect(result[1].friendReply == "You got this")
    }

    @Test func updateForUnknownIdIsInserted() {
        // We missed the INSERT (disconnected / before load) — the UPDATE is the freshest state.
        let list = [makeNudge(id: 1, sentOffset: 10)]
        let updated = makeNudge(id: 2, sentOffset: 20, status: .replyDelivered, type: .shame, reply: "Get off")

        let result = NudgeHistoryMerge.applying(.updated(updated), to: list, friendId: friendId)

        #expect(result.map(\.id) == [2, 1])
        #expect(result[0] == updated)
    }

    @Test func insertForAnotherFriendIsIgnored() {
        let list = [makeNudge(id: 1)]
        let foreign = makeNudge(id: 2, friendId: 99, sentOffset: 50)

        let result = NudgeHistoryMerge.applying(.inserted(foreign), to: list, friendId: friendId)

        #expect(result == list)
    }

    @Test func updateForAnotherFriendIsIgnored() {
        let list = [makeNudge(id: 1)]
        let foreign = makeNudge(id: 1, friendId: 99, status: .replied)

        let result = NudgeHistoryMerge.applying(.updated(foreign), to: list, friendId: friendId)

        #expect(result == list)
    }

    @Test func subscribedSignalLeavesListUnchanged() {
        let list = [makeNudge(id: 2, sentOffset: 20), makeNudge(id: 1, sentOffset: 10)]

        let result = NudgeHistoryMerge.applying(.subscribed, to: list, friendId: friendId)

        #expect(result == list)
    }

    @Test func sortedIsNewestFirstWithIdTieBreak() {
        let list = [
            makeNudge(id: 1, sentOffset: 10),
            makeNudge(id: 4, sentOffset: 20),
            makeNudge(id: 3, sentOffset: 30),
            makeNudge(id: 5, sentOffset: 20),
        ]

        #expect(NudgeHistoryMerge.sorted(list).map(\.id) == [3, 5, 4, 1])
    }
}

// MARK: - Realtime record decoding

@Suite("Realtime nudge record decoding")
@MainActor
struct RealtimeNudgeDecodingTests {

    /// Parses JSON into the `JSONObject` shape Realtime hands us in `InsertAction.record`.
    private func record(_ json: String) throws -> JSONObject {
        try JSONDecoder().decode(JSONObject.self, from: Data(json.utf8))
    }

    @Test func decodesInsertRecordWithNullTypeAndReply() throws {
        // Realistic walrus payload: bigint as number, timestamptz with microseconds + offset.
        let json = """
        {
          "id": 42,
          "friend_id": 7,
          "prompt": "Josh has been on their phone for 60 minutes straight.",
          "friend_reply": null,
          "type": null,
          "status": "sent_to_friend",
          "sent_timestamp": "2026-11-14T17:03:21.578839+00:00"
        }
        """

        let nudge = try NudgeRealtimeService.decodeNudge(from: record(json))

        #expect(nudge.id == 42)
        #expect(nudge.friendId == 7)
        #expect(nudge.prompt == "Josh has been on their phone for 60 minutes straight.")
        #expect(nudge.friendReply == nil)
        #expect(nudge.type == nil)
        #expect(nudge.status == .sentToFriend)
        let expected = Date(timeIntervalSince1970: 1_794_675_801.578)
        #expect(abs(nudge.sentTimestamp.timeIntervalSince(expected)) < 0.01)
    }

    @Test func decodesUpdateRecordAfterReply() throws {
        let json = """
        {
          "id": 42,
          "friend_id": 7,
          "prompt": "Josh has been on their phone for 60 minutes straight.",
          "friend_reply": "Go touch grass",
          "type": "custom",
          "status": "replied",
          "sent_timestamp": "2026-11-14T17:03:21+00:00"
        }
        """

        let nudge = try NudgeRealtimeService.decodeNudge(from: record(json))

        #expect(nudge.status == .replied)
        #expect(nudge.type == .custom)
        #expect(nudge.friendReply == "Go touch grass")
    }

    @Test func decodesReplyDeliveredStatus() throws {
        let json = """
        {"id": 1, "friend_id": 2, "prompt": "p", "friend_reply": "r", "type": "shame",
         "status": "reply_delivered", "sent_timestamp": "2026-11-14T17:03:21.5+00:00"}
        """

        let nudge = try NudgeRealtimeService.decodeNudge(from: record(json))

        #expect(nudge.status == .replyDelivered)
        #expect(nudge.type == .shame)
    }

    @Test func recordMissingRequiredColumnThrows() throws {
        let json = """
        {"id": 1, "prompt": "p", "status": "replied", "sent_timestamp": "2026-11-14T17:03:21+00:00"}
        """
        let rec = try record(json)

        #expect(throws: (any Error).self) {
            _ = try NudgeRealtimeService.decodeNudge(from: rec)
        }
    }
}

// MARK: - Mocks

private struct TestError: LocalizedError {
    var errorDescription: String? { "History unavailable" }
}

private final class MockHistoryFriendService: FriendServiceProtocol {
    /// Results returned by successive `fetchNudgeHistory` calls; the last one repeats.
    var historyResults: [Result<[Nudge], Error>] = [.success([])]
    private(set) var fetchHistoryCallCount = 0
    private(set) var requestedFriendIds: [Int] = []

    func fetchFriends(userId: UUID) async throws -> [Friend] { [] }
    func addFriend(userId: UUID, name: String, phoneNumber: String) async throws {}
    func deleteFriend(id: Int) async throws {}
    func updateFriendName(id: Int, name: String) async throws {}
    func fetchFriendId(forNudgeId nudgeId: Int) async throws -> Int? { nil }

    func fetchNudgeHistory(friendId: Int) async throws -> [Nudge] {
        let index = min(fetchHistoryCallCount, historyResults.count - 1)
        fetchHistoryCallCount += 1
        requestedFriendIds.append(friendId)
        return try historyResults[index].get()
    }
}

private final class MockNudgeRealtimeService: NudgeRealtimeServiceProtocol {
    private(set) var requestedFriendIds: [Int] = []
    private(set) var continuation: AsyncStream<NudgeChange>.Continuation?
    private(set) var terminationCount = 0

    func changes(friendId: Int) -> AsyncStream<NudgeChange> {
        requestedFriendIds.append(friendId)
        let (stream, continuation) = AsyncStream<NudgeChange>.makeStream()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.terminationCount += 1 }
        }
        self.continuation = continuation
        return stream
    }
}

// MARK: - NudgeHistoryViewModel — loading

@Suite("NudgeHistoryViewModel loading")
@MainActor
struct NudgeHistoryViewModelLoadTests {

    @Test func loadPublishesSortedHistoryForTheFriend() async {
        let service = MockHistoryFriendService()
        service.historyResults = [.success([makeNudge(id: 1, sentOffset: 10), makeNudge(id: 2, sentOffset: 20)])]
        let vm = NudgeHistoryViewModel(friendId: 7, friendService: service, realtimeService: MockNudgeRealtimeService())

        await vm.load()

        #expect(vm.nudges.map(\.id) == [2, 1])
        #expect(vm.isLoading == false)
        #expect(vm.error == nil)
        #expect(service.requestedFriendIds == [7])
    }

    @Test func loadFailureSetsError() async {
        let service = MockHistoryFriendService()
        service.historyResults = [.failure(TestError())]
        let vm = NudgeHistoryViewModel(friendId: 7, friendService: service, realtimeService: MockNudgeRealtimeService())

        await vm.load()

        #expect(vm.error == "History unavailable")
        #expect(vm.nudges.isEmpty)
        #expect(vm.isLoading == false)
    }

    @Test func retryAfterFailureClearsError() async {
        let service = MockHistoryFriendService()
        service.historyResults = [.failure(TestError()), .success([makeNudge(id: 1)])]
        let vm = NudgeHistoryViewModel(friendId: 7, friendService: service, realtimeService: MockNudgeRealtimeService())

        await vm.load()
        await vm.load()

        #expect(vm.error == nil)
        #expect(vm.nudges.map(\.id) == [1])
    }

    @Test func refreshReplacesListWithLatestServerState() async {
        let service = MockHistoryFriendService()
        service.historyResults = [
            .success([makeNudge(id: 1)]),
            .success([makeNudge(id: 1, status: .replied, type: .custom, reply: "ok")]),
        ]
        let vm = NudgeHistoryViewModel(friendId: 7, friendService: service, realtimeService: MockNudgeRealtimeService())
        await vm.load()

        await vm.refresh()

        #expect(vm.nudges.first?.status == .replied)
        #expect(vm.error == nil)
    }

    @Test func refreshFailureKeepsExistingListWithoutError() async {
        let service = MockHistoryFriendService()
        service.historyResults = [.success([makeNudge(id: 1)]), .failure(TestError())]
        let vm = NudgeHistoryViewModel(friendId: 7, friendService: service, realtimeService: MockNudgeRealtimeService())
        await vm.load()

        await vm.refresh()

        #expect(vm.nudges.map(\.id) == [1])
        #expect(vm.error == nil)
        #expect(vm.isLoading == false)
    }

    @Test func refreshFailureWithNothingToShowSetsError() async {
        let service = MockHistoryFriendService()
        service.historyResults = [.failure(TestError())]
        let vm = NudgeHistoryViewModel(friendId: 7, friendService: service, realtimeService: MockNudgeRealtimeService())

        await vm.refresh()

        #expect(vm.error == "History unavailable")
    }

    @Test func refreshSuccessClearsAnEarlierError() async {
        let service = MockHistoryFriendService()
        service.historyResults = [.failure(TestError()), .success([makeNudge(id: 1)])]
        let vm = NudgeHistoryViewModel(friendId: 7, friendService: service, realtimeService: MockNudgeRealtimeService())
        await vm.load()

        await vm.refresh()

        #expect(vm.error == nil)
        #expect(vm.nudges.map(\.id) == [1])
    }
}

// MARK: - NudgeHistoryViewModel — realtime

@Suite("NudgeHistoryViewModel realtime")
@MainActor
struct NudgeHistoryViewModelRealtimeTests {

    @Test func startLoadsThenAppliesStreamedInsertAndUpdate() async {
        let service = MockHistoryFriendService()
        service.historyResults = [.success([makeNudge(id: 1, sentOffset: 10)])]
        let realtime = MockNudgeRealtimeService()
        let vm = NudgeHistoryViewModel(friendId: 7, friendService: service, realtimeService: realtime)

        let task = Task { await vm.start() }
        #expect(await waitUntil { realtime.continuation != nil && vm.nudges.count == 1 && !vm.isLoading })
        #expect(realtime.requestedFriendIds == [7])
        #expect(vm.isObserving)

        realtime.continuation?.yield(.inserted(makeNudge(id: 2, sentOffset: 20)))
        #expect(await waitUntil { vm.nudges.map(\.id) == [2, 1] })

        let replied = makeNudge(id: 2, sentOffset: 20, status: .replied, type: .encouragement, reply: "Yay")
        realtime.continuation?.yield(.updated(replied))
        #expect(await waitUntil { vm.nudges.first == replied })

        realtime.continuation?.finish()
        await task.value
    }

    @Test func eventsForOtherFriendsAreIgnored() async {
        let service = MockHistoryFriendService()
        service.historyResults = [.success([makeNudge(id: 1)])]
        let realtime = MockNudgeRealtimeService()
        let vm = NudgeHistoryViewModel(friendId: 7, friendService: service, realtimeService: realtime)

        let task = Task { await vm.start() }
        #expect(await waitUntil { realtime.continuation != nil && vm.nudges.count == 1 })

        realtime.continuation?.yield(.inserted(makeNudge(id: 9, friendId: 99, sentOffset: 99)))
        realtime.continuation?.yield(.inserted(makeNudge(id: 3, sentOffset: 30)))  // marker
        #expect(await waitUntil { vm.nudges.count == 2 })
        #expect(vm.nudges.map(\.id) == [3, 1])

        realtime.continuation?.finish()
        await task.value
    }

    @Test func subscribedSignalTriggersRefetch() async {
        let service = MockHistoryFriendService()
        service.historyResults = [
            .success([makeNudge(id: 1)]),
            .success([makeNudge(id: 2, sentOffset: 20), makeNudge(id: 1)]),  // missed while offline
        ]
        let realtime = MockNudgeRealtimeService()
        let vm = NudgeHistoryViewModel(friendId: 7, friendService: service, realtimeService: realtime)

        let task = Task { await vm.start() }
        #expect(await waitUntil { realtime.continuation != nil && service.fetchHistoryCallCount == 1 && !vm.isLoading })

        realtime.continuation?.yield(.subscribed)
        #expect(await waitUntil { service.fetchHistoryCallCount == 2 })
        #expect(await waitUntil { vm.nudges.map(\.id) == [2, 1] })

        realtime.continuation?.finish()
        await task.value
    }

    @Test func streamEndingReturnsCleanlyAndKeepsList() async {
        let service = MockHistoryFriendService()
        service.historyResults = [.success([makeNudge(id: 1)])]
        let realtime = MockNudgeRealtimeService()
        let vm = NudgeHistoryViewModel(friendId: 7, friendService: service, realtimeService: realtime)

        let task = Task { await vm.start() }
        #expect(await waitUntil { realtime.continuation != nil && vm.nudges.count == 1 })

        realtime.continuation?.finish()
        await task.value

        #expect(vm.nudges.map(\.id) == [1])
        #expect(vm.error == nil)
        #expect(vm.isObserving == false)
    }

    @Test func cancellingStartTerminatesTheStream() async {
        // `.task` cancels on disappear — the realtime stream (and its channel) must be torn down.
        let service = MockHistoryFriendService()
        service.historyResults = [.success([makeNudge(id: 1)])]
        let realtime = MockNudgeRealtimeService()
        let vm = NudgeHistoryViewModel(friendId: 7, friendService: service, realtimeService: realtime)

        let task = Task { await vm.start() }
        #expect(await waitUntil { realtime.continuation != nil && vm.nudges.count == 1 })

        task.cancel()
        await task.value

        #expect(await waitUntil { realtime.terminationCount == 1 })
        #expect(vm.isObserving == false)
    }

    @Test func restartingAfterDisappearOpensOneNewStreamAndRefreshesWithoutSpinner() async {
        let service = MockHistoryFriendService()
        service.historyResults = [.success([makeNudge(id: 1)])]
        let realtime = MockNudgeRealtimeService()
        let vm = NudgeHistoryViewModel(friendId: 7, friendService: service, realtimeService: realtime)

        let first = Task { await vm.start() }
        #expect(await waitUntil { vm.nudges.count == 1 })
        first.cancel()
        await first.value

        let second = Task { await vm.start() }
        #expect(await waitUntil { service.fetchHistoryCallCount == 2 && realtime.requestedFriendIds.count == 2 })
        #expect(vm.nudges.map(\.id) == [1])
        second.cancel()
        await second.value

        #expect(await waitUntil { realtime.terminationCount == 2 })
    }

    @Test func foregroundRefreshesOnlyWhileObserving() async {
        let service = MockHistoryFriendService()
        service.historyResults = [.success([makeNudge(id: 1)])]
        let realtime = MockNudgeRealtimeService()
        let vm = NudgeHistoryViewModel(friendId: 7, friendService: service, realtimeService: realtime)

        // Not on screen → no fetch.
        await vm.sceneDidBecomeActive()
        #expect(service.fetchHistoryCallCount == 0)

        let task = Task { await vm.start() }
        #expect(await waitUntil { realtime.continuation != nil && service.fetchHistoryCallCount == 1 && !vm.isLoading })

        await vm.sceneDidBecomeActive()
        #expect(service.fetchHistoryCallCount == 2)

        realtime.continuation?.finish()
        await task.value
    }
}

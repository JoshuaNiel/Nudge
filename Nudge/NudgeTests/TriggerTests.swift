import Testing
import Foundation
@testable import Nudge

// MARK: - PendingTrigger Coding

@Suite("PendingTrigger Coding")
@MainActor
struct PendingTriggerCodingTests {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test func roundTripIncludesReport() throws {
        let trigger = PendingTrigger(
            eventName: "app.com.instagram.Instagram",
            report: "Josh just hit their 30-minute limit on Instagram.",
            timestamp: Date(timeIntervalSince1970: 1_000_000)
        )
        let data = try encoder.encode(trigger)
        let decoded = try decoder.decode(PendingTrigger.self, from: data)

        #expect(decoded.eventName == trigger.eventName)
        #expect(decoded.report == trigger.report)
        #expect(decoded.timestamp == trigger.timestamp)
    }

    @Test func encodesSnakeCaseKeys() throws {
        let trigger = PendingTrigger(
            eventName: "total",
            report: "Josh hit their daily limit.",
            timestamp: Date()
        )
        let data = try encoder.encode(trigger)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["event_name"] != nil, "event_name key missing")
        #expect(json["eventName"] == nil, "camelCase should not appear")
        #expect(json["report"] as? String == "Josh hit their daily limit.")
    }

    @Test func roundTripIncludesSentFriendIds() throws {
        let trigger = PendingTrigger(
            eventName: "total",
            report: "r",
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            sentFriendIds: [3, 7]
        )
        let data = try encoder.encode(trigger)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let decoded = try decoder.decode(PendingTrigger.self, from: data)

        #expect(json["sent_friend_ids"] as? [Int] == [3, 7])
        #expect(json["sentFriendIds"] == nil, "camelCase should not appear")
        #expect(decoded.sentFriendIds == [3, 7])
    }

    @Test func memberwiseInitDefaultsToNoFriendsSent() {
        let trigger = PendingTrigger(eventName: "total", report: "r", timestamp: Date())
        #expect(trigger.sentFriendIds.isEmpty)
    }

    /// Queue entries written by a build before `sentFriendIds` existed must still
    /// decode — otherwise the whole queue would fail to load.
    @Test func decodesLegacyJSONWithoutSentFriendIds() throws {
        let json = """
        [{"event_name":"total","report":"r","timestamp":700000000}]
        """
        let decoded = try decoder.decode([PendingTrigger].self, from: Data(json.utf8))

        #expect(decoded.count == 1)
        #expect(decoded.first?.eventName == "total")
        #expect(decoded.first?.sentFriendIds == [])
    }
}

// MARK: - Mocks

private final class MockPendingTriggerStore: PendingTriggerStore {
    var triggers: [PendingTrigger]

    init(_ triggers: [PendingTrigger] = []) {
        self.triggers = triggers
    }

    func load() -> [PendingTrigger] {
        triggers
    }

    func save(_ triggers: [PendingTrigger]) {
        self.triggers = triggers
    }
}

@MainActor
private final class MockNudgeService: NudgeServiceProtocol {
    var errorToThrow: Error? = nil
    /// Sends to these friends throw; sends to everyone else succeed.
    var failingFriendIds: Set<Int> = []
    /// Runs on every attempt, before the result — used to observe or mutate the
    /// store mid-drain.
    var onAttempt: ((Int) -> Void)? = nil
    /// Successful sends only.
    private(set) var calls: [(friendId: Int, report: String)] = []
    /// Every attempt, successful or not.
    private(set) var attempts: [(friendId: Int, report: String)] = []

    func sendNudge(friendId: Int, report: String) async throws {
        attempts.append((friendId, report))
        onAttempt?(friendId)
        if let error = errorToThrow { throw error }
        if failingFriendIds.contains(friendId) { throw URLError(.badServerResponse) }
        calls.append((friendId, report))
    }
}

@MainActor
private final class MockFriendService: FriendServiceProtocol {
    var friendsToReturn: [Friend] = []
    var errorToThrow: Error? = nil
    /// When true, `fetchFriends` suspends until `release()` is called, so a test
    /// can hold a drain in flight.
    var holdFetch = false
    private(set) var fetchCount = 0
    private var heldContinuation: CheckedContinuation<Void, Never>?

    var isHoldingFetch: Bool { heldContinuation != nil }

    func release() {
        heldContinuation?.resume()
        heldContinuation = nil
    }

    func fetchFriends(userId: UUID) async throws -> [Friend] {
        fetchCount += 1
        if holdFetch {
            await withCheckedContinuation { heldContinuation = $0 }
        }
        if let error = errorToThrow { throw error }
        return friendsToReturn
    }

    func addFriend(userId: UUID, name: String, phoneNumber: String) async throws {}
    func deleteFriend(id: Int) async throws {}
    func updateFriendName(id: Int, name: String) async throws {}
    func fetchNudgeHistory(friendId: Int) async throws -> [Nudge] { [] }
}

private func makeFriend(id: Int, status: FriendStatus = .accepted) -> Friend {
    Friend(
        id: id,
        userId: UUID(),
        friendName: "Friend \(id)",
        friendPhoneNumber: "+18015550000",
        status: status,
        invitationTimestamp: Date()
    )
}

private func makeTrigger(
    _ name: String,
    report: String,
    timestamp: Date = Date(),
    sentFriendIds: [Int] = []
) -> PendingTrigger {
    PendingTrigger(eventName: name, report: report, timestamp: timestamp, sentFriendIds: sentFriendIds)
}

private func denverCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Denver")!
    return cal
}

/// A wall-clock time in `America/Denver`.
private func denver(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
    return denverCalendar().date(from: c)!
}

// MARK: - NudgeTriggerService

/// `.serialized` because the single-flight guard is a process-wide static: a drain
/// held in flight by one test would make a parallel test's drain return early.
@Suite("NudgeTriggerService", .serialized)
@MainActor
struct NudgeTriggerServiceTests {

    @Test func drainsAndSendsOneNudgePerTriggerPerAcceptedFriend() async {
        let store = MockPendingTriggerStore([
            makeTrigger("total", report: "report-A"),
            makeTrigger("app.x", report: "report-B"),
        ])
        let nudge = MockNudgeService()
        let friends = MockFriendService()
        friends.friendsToReturn = [makeFriend(id: 1), makeFriend(id: 2)]

        let service = NudgeTriggerService(store: store, nudgeService: nudge, friendService: friends)
        await service.drainPendingTriggers(userId: UUID())

        // 2 triggers × 2 friends = 4 sends
        #expect(nudge.calls.count == 4)
        #expect(nudge.calls.contains { $0.friendId == 1 && $0.report == "report-A" })
        #expect(nudge.calls.contains { $0.friendId == 2 && $0.report == "report-A" })
        #expect(nudge.calls.contains { $0.friendId == 1 && $0.report == "report-B" })
        #expect(nudge.calls.contains { $0.friendId == 2 && $0.report == "report-B" })
        // processed triggers removed
        #expect(store.triggers.isEmpty)
    }

    @Test func onlyAcceptedFriendsReceiveNudges() async {
        let store = MockPendingTriggerStore([makeTrigger("total", report: "r")])
        let nudge = MockNudgeService()
        let friends = MockFriendService()
        friends.friendsToReturn = [
            makeFriend(id: 1, status: .accepted),
            makeFriend(id: 2, status: .pending),
            makeFriend(id: 3, status: .blocked),
        ]

        let service = NudgeTriggerService(store: store, nudgeService: nudge, friendService: friends)
        await service.drainPendingTriggers(userId: UUID())

        #expect(nudge.calls.count == 1)
        #expect(nudge.calls.first?.friendId == 1)
        #expect(store.triggers.isEmpty)
    }

    @Test func emptyStoreMakesNoSends() async {
        let store = MockPendingTriggerStore([])
        let nudge = MockNudgeService()
        let friends = MockFriendService()
        friends.friendsToReturn = [makeFriend(id: 1)]

        let service = NudgeTriggerService(store: store, nudgeService: nudge, friendService: friends)
        await service.drainPendingTriggers(userId: UUID())

        #expect(nudge.calls.isEmpty)
    }

    @Test func sendFailureRetainsTrigger() async {
        let store = MockPendingTriggerStore([makeTrigger("total", report: "r")])
        let nudge = MockNudgeService()
        nudge.errorToThrow = URLError(.notConnectedToInternet)
        let friends = MockFriendService()
        friends.friendsToReturn = [makeFriend(id: 1)]

        let service = NudgeTriggerService(store: store, nudgeService: nudge, friendService: friends)
        await service.drainPendingTriggers(userId: UUID())

        #expect(store.triggers.count == 1, "failed trigger must be retained for retry")
    }

    @Test func friendFetchFailureLeavesStoreUnchanged() async {
        let store = MockPendingTriggerStore([makeTrigger("total", report: "r")])
        let nudge = MockNudgeService()
        let friends = MockFriendService()
        friends.errorToThrow = URLError(.notConnectedToInternet)

        let service = NudgeTriggerService(store: store, nudgeService: nudge, friendService: friends)
        await service.drainPendingTriggers(userId: UUID())

        #expect(store.triggers.count == 1, "store must be untouched on fetch failure")
        #expect(nudge.calls.isEmpty)
    }

    @Test func zeroAcceptedFriendsClearsStore() async {
        let store = MockPendingTriggerStore([makeTrigger("total", report: "r")])
        let nudge = MockNudgeService()
        let friends = MockFriendService()
        friends.friendsToReturn = [makeFriend(id: 2, status: .pending)]

        let service = NudgeTriggerService(store: store, nudgeService: nudge, friendService: friends)
        await service.drainPendingTriggers(userId: UUID())

        #expect(store.triggers.isEmpty, "no one to send to → clear pending")
        #expect(nudge.calls.isEmpty)
    }

    // MARK: Rule 1 — expire at the end of the trigger's day

    @Test func dropsYesterdaysTriggerWithoutSendingAndKeepsTodays() async {
        let now = denver(2026, 11, 23, 9, 0)
        let store = MockPendingTriggerStore([
            makeTrigger("total", report: "yesterday", timestamp: denver(2026, 11, 22, 23, 59)),
            makeTrigger("total", report: "today", timestamp: denver(2026, 11, 23, 0, 1)),
        ])
        let nudge = MockNudgeService()
        nudge.errorToThrow = URLError(.notConnectedToInternet)
        let friends = MockFriendService()
        friends.friendsToReturn = [makeFriend(id: 1)]

        let service = NudgeTriggerService(
            store: store, nudgeService: nudge, friendService: friends,
            now: { now }, calendar: denverCalendar()
        )
        await service.drainPendingTriggers(userId: UUID())

        #expect(!nudge.attempts.contains { $0.report == "yesterday" }, "expired trigger must not be sent")
        #expect(store.triggers.map(\.report) == ["today"], "yesterday dropped, today kept (send failed)")
    }

    /// The day is the *local* calendar day: 05:00 UTC on the 23rd is still the
    /// evening of the 22nd in Denver, so it has expired by 09:00 Denver on the 23rd.
    @Test func expiryUsesLocalCalendarDayNotUTC() async {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let lateEveningLocal = utc.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 5))!

        let store = MockPendingTriggerStore([makeTrigger("total", report: "r", timestamp: lateEveningLocal)])
        let nudge = MockNudgeService()
        let friends = MockFriendService()
        friends.friendsToReturn = [makeFriend(id: 1)]

        let service = NudgeTriggerService(
            store: store, nudgeService: nudge, friendService: friends,
            now: { denver(2026, 11, 23, 9, 0) }, calendar: denverCalendar()
        )
        await service.drainPendingTriggers(userId: UUID())

        #expect(nudge.attempts.isEmpty)
        #expect(store.triggers.isEmpty)
    }

    @Test func expiredTriggersAreDroppedEvenWhenFriendFetchFails() async {
        let store = MockPendingTriggerStore([
            makeTrigger("total", report: "old", timestamp: denver(2026, 11, 14, 12, 0)),
            makeTrigger("total", report: "today", timestamp: denver(2026, 11, 23, 8, 0)),
        ])
        let nudge = MockNudgeService()
        let friends = MockFriendService()
        friends.errorToThrow = URLError(.notConnectedToInternet)

        let service = NudgeTriggerService(
            store: store, nudgeService: nudge, friendService: friends,
            now: { denver(2026, 11, 23, 9, 0) }, calendar: denverCalendar()
        )
        await service.drainPendingTriggers(userId: UUID())

        #expect(store.triggers.map(\.report) == ["today"])
        #expect(nudge.attempts.isEmpty)
    }

    // MARK: Rule 2 — stop at the first failed send

    @Test func stopsAtFirstFailureAndLeavesLaterTriggersUntouched() async {
        let store = MockPendingTriggerStore([
            makeTrigger("total", report: "A"),
            makeTrigger("session.timeout", report: "B"),
        ])
        let nudge = MockNudgeService()
        nudge.errorToThrow = URLError(.badServerResponse)
        let friends = MockFriendService()
        friends.friendsToReturn = [makeFriend(id: 1), makeFriend(id: 2)]

        let service = NudgeTriggerService(store: store, nudgeService: nudge, friendService: friends)
        await service.drainPendingTriggers(userId: UUID())

        #expect(nudge.attempts.count == 1, "no further send attempts after the first failure")
        #expect(store.triggers.map(\.report) == ["A", "B"])
        #expect(store.triggers.allSatisfy { $0.sentFriendIds.isEmpty })
    }

    // MARK: Rule 3 — per-friend progress

    @Test func persistsPartialProgressAndRetriesOnlyRemainingFriends() async {
        let store = MockPendingTriggerStore([makeTrigger("total", report: "r")])
        let nudge = MockNudgeService()
        nudge.failingFriendIds = [2]
        let friends = MockFriendService()
        friends.friendsToReturn = [makeFriend(id: 1), makeFriend(id: 2)]

        await NudgeTriggerService(store: store, nudgeService: nudge, friendService: friends)
            .drainPendingTriggers(userId: UUID())

        #expect(store.triggers.count == 1)
        #expect(store.triggers.first?.sentFriendIds == [1], "friend 1's send must be recorded")

        let retryNudge = MockNudgeService()
        await NudgeTriggerService(store: store, nudgeService: retryNudge, friendService: friends)
            .drainPendingTriggers(userId: UUID())

        #expect(retryNudge.calls.map(\.friendId) == [2], "retry must skip friend 1")
        #expect(store.triggers.isEmpty)
    }

    /// Progress is persisted before the drain moves on, so a crash mid-drain can't
    /// re-send to a friend who already got the nudge.
    @Test func progressIsPersistedBeforeTheNextSend() async {
        let store = MockPendingTriggerStore([makeTrigger("total", report: "r")])
        let nudge = MockNudgeService()
        var sentIdsSeenAtFriend2: [Int]?
        nudge.onAttempt = { friendId in
            if friendId == 2 { sentIdsSeenAtFriend2 = store.triggers.first?.sentFriendIds }
        }
        let friends = MockFriendService()
        friends.friendsToReturn = [makeFriend(id: 1), makeFriend(id: 2)]

        await NudgeTriggerService(store: store, nudgeService: nudge, friendService: friends)
            .drainPendingTriggers(userId: UUID())

        #expect(sentIdsSeenAtFriend2 == [1])
    }

    @Test func removedFriendDoesNotBlockCompletion() async {
        let store = MockPendingTriggerStore([
            makeTrigger("total", report: "done", sentFriendIds: [1, 99]),
            makeTrigger("session.timeout", report: "half", sentFriendIds: [99]),
        ])
        let nudge = MockNudgeService()
        let friends = MockFriendService()
        friends.friendsToReturn = [makeFriend(id: 1)]  // friend 99 no longer accepted

        await NudgeTriggerService(store: store, nudgeService: nudge, friendService: friends)
            .drainPendingTriggers(userId: UUID())

        #expect(nudge.calls.map(\.report) == ["half"], "only the trigger missing friend 1 sends")
        #expect(store.triggers.isEmpty)
    }

    // MARK: Rule 4 — single flight

    @Test func concurrentSecondDrainMakesNoSends() async {
        let store = MockPendingTriggerStore([makeTrigger("total", report: "r")])
        let nudge = MockNudgeService()
        let friends = MockFriendService()
        friends.friendsToReturn = [makeFriend(id: 1)]
        friends.holdFetch = true

        let first = Task {
            await NudgeTriggerService(store: store, nudgeService: nudge, friendService: friends)
                .drainPendingTriggers(userId: UUID())
        }
        while !friends.isHoldingFetch { await Task.yield() }

        // A second, separate service instance while the first drain is in flight.
        let secondNudge = MockNudgeService()
        await NudgeTriggerService(store: store, nudgeService: secondNudge, friendService: friends)
            .drainPendingTriggers(userId: UUID())

        #expect(secondNudge.attempts.isEmpty)
        #expect(friends.fetchCount == 1, "second drain must return before doing any work")

        friends.release()
        await first.value

        #expect(nudge.calls.count == 1)
        #expect(store.triggers.isEmpty)

        // The flag is reset once the first drain finishes.
        store.triggers = [makeTrigger("total", report: "again")]
        friends.holdFetch = false
        let thirdNudge = MockNudgeService()
        await NudgeTriggerService(store: store, nudgeService: thirdNudge, friendService: friends)
            .drainPendingTriggers(userId: UUID())
        #expect(thirdNudge.calls.count == 1)
    }

    // MARK: Concurrency with the extension

    @Test func triggerAppendedMidDrainSurvives() async {
        let store = MockPendingTriggerStore([makeTrigger("total", report: "seen")])
        let nudge = MockNudgeService()
        let appended = makeTrigger("session.timeout", report: "appended")
        nudge.onAttempt = { _ in
            if !store.triggers.contains(where: { $0.report == "appended" }) {
                store.triggers.append(appended)  // the extension enqueues mid-drain
            }
        }
        let friends = MockFriendService()
        friends.friendsToReturn = [makeFriend(id: 1)]

        await NudgeTriggerService(store: store, nudgeService: nudge, friendService: friends)
            .drainPendingTriggers(userId: UUID())

        #expect(store.triggers.map(\.report) == ["appended"])
    }

    @Test func zeroAcceptedFriendsKeepsTriggerAppendedAfterLoad() async {
        let store = MockPendingTriggerStore([makeTrigger("total", report: "seen")])
        let nudge = MockNudgeService()
        let friends = FetchHookFriendService { store.triggers.append(makeTrigger("total", report: "late")) }

        await NudgeTriggerService(store: store, nudgeService: nudge, friendService: friends)
            .drainPendingTriggers(userId: UUID())

        #expect(store.triggers.map(\.report) == ["late"])
        #expect(nudge.attempts.isEmpty)
    }
}

/// Returns no friends, running `onFetch` first — simulates the extension enqueuing
/// while the friend fetch is in flight.
@MainActor
private final class FetchHookFriendService: FriendServiceProtocol {
    private let onFetch: () -> Void
    init(onFetch: @escaping () -> Void) { self.onFetch = onFetch }

    func fetchFriends(userId: UUID) async throws -> [Friend] {
        onFetch()
        return []
    }
    func addFriend(userId: UUID, name: String, phoneNumber: String) async throws {}
    func deleteFriend(id: Int) async throws {}
    func updateFriendName(id: Int, name: String) async throws {}
    func fetchNudgeHistory(friendId: Int) async throws -> [Nudge] { [] }
}

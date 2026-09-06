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
    private(set) var calls: [(friendId: Int, report: String)] = []

    func sendNudge(friendId: Int, report: String) async throws {
        if let error = errorToThrow { throw error }
        calls.append((friendId, report))
    }
}

@MainActor
private final class MockFriendService: FriendServiceProtocol {
    var friendsToReturn: [Friend] = []
    var errorToThrow: Error? = nil

    func fetchFriends(userId: UUID) async throws -> [Friend] {
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

private func makeTrigger(_ name: String, report: String) -> PendingTrigger {
    PendingTrigger(eventName: name, report: report, timestamp: Date())
}

// MARK: - NudgeTriggerService

@Suite("NudgeTriggerService")
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
}

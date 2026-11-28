import Testing
import Foundation
import UserNotifications
@testable import Nudge

// Phase 5F — APNs registration + push deep-link.
// Covers the pure / mockable logic only; the UIKit calls (registerForRemoteNotifications,
// the notification-center delegate) are deliberately thin wrappers around these.

// MARK: - Device token hex encoding

@Suite("DeviceToken hex encoding")
@MainActor
struct DeviceTokenEncodingTests {

    @Test func encodesBytesAsLowercaseZeroPaddedHex() {
        let data = Data([0x00, 0x0f, 0xab, 0xff, 0x10])
        #expect(DeviceToken.hexString(from: data) == "000fabff10")
    }

    @Test func emptyDataEncodesAsEmptyString() {
        #expect(DeviceToken.hexString(from: Data()) == "")
    }

    @Test func thirtyTwoByteTokenProducesSixtyFourHexChars() {
        let data = Data((0..<32).map { UInt8($0) })
        let hex = DeviceToken.hexString(from: data)
        #expect(hex.count == 64)
        #expect(hex.hasPrefix("00010203"))
        #expect(hex.hasSuffix("1d1e1f"))
    }
}

// MARK: - DeviceTokenInsert encoding

@Suite("DeviceTokenInsert Encoding")
@MainActor
struct DeviceTokenInsertEncodingTests {

    private func encodedKeys(_ insert: DeviceTokenInsert) throws -> [String: Any] {
        let data = try JSONEncoder().encode(insert)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func encodesSnakeCaseKeys() throws {
        let insert = DeviceTokenInsert(userId: UUID(), token: "abc123", updatedAt: Date())
        let json = try encodedKeys(insert)

        #expect(json["user_id"] != nil)
        #expect(json["token"] as? String == "abc123")
        #expect(json["platform"] as? String == "apns")
        #expect(json["updated_at"] != nil)
    }

    @Test func doesNotEncodeCamelCaseKeys() throws {
        let json = try encodedKeys(DeviceTokenInsert(userId: UUID(), token: "t", updatedAt: Date()))
        #expect(json["userId"] == nil)
        #expect(json["updatedAt"] == nil)
        #expect(json.count == 4)
    }

    @Test func platformDefaultsToApns() {
        #expect(DeviceTokenInsert(userId: UUID(), token: "t", updatedAt: Date()).platform == "apns")
    }
}

// MARK: - Push payload parsing

@Suite("PushPayload nudge_id parsing")
@MainActor
struct PushPayloadTests {

    @Test func parsesIntAtTopLevel() {
        #expect(PushPayload.nudgeId(from: ["nudge_id": 42]) == 42)
    }

    @Test func parsesNSNumber() {
        #expect(PushPayload.nudgeId(from: ["nudge_id": NSNumber(value: 7)]) == 7)
    }

    @Test func parsesNumericString() {
        #expect(PushPayload.nudgeId(from: ["nudge_id": "99"]) == 99)
        #expect(PushPayload.nudgeId(from: ["nudge_id": " 99 "]) == 99)
    }

    @Test func parsesIntegralDouble() {
        #expect(PushPayload.nudgeId(from: ["nudge_id": 12.0]) == 12)
    }

    @Test func missingKeyReturnsNil() {
        #expect(PushPayload.nudgeId(from: ["aps": ["alert": "hi"]]) == nil)
        #expect(PushPayload.nudgeId(from: [:]) == nil)
    }

    @Test func garbageReturnsNil() {
        #expect(PushPayload.nudgeId(from: ["nudge_id": "abc"]) == nil)
        #expect(PushPayload.nudgeId(from: ["nudge_id": ""]) == nil)
        #expect(PushPayload.nudgeId(from: ["nudge_id": "12abc"]) == nil)
        #expect(PushPayload.nudgeId(from: ["nudge_id": 12.5]) == nil)
        #expect(PushPayload.nudgeId(from: ["nudge_id": ["id": 1]]) == nil)
        #expect(PushPayload.nudgeId(from: ["nudge_id": NSNull()]) == nil)
    }

    @Test func booleansAreRejected() {
        #expect(PushPayload.nudgeId(from: ["nudge_id": true]) == nil)
        #expect(PushPayload.nudgeId(from: ["nudge_id": NSNumber(value: true)]) == nil)
    }

    @Test func nonPositiveIdsAreRejected() {
        #expect(PushPayload.nudgeId(from: ["nudge_id": 0]) == nil)
        #expect(PushPayload.nudgeId(from: ["nudge_id": -3]) == nil)
        #expect(PushPayload.nudgeId(from: ["nudge_id": "-3"]) == nil)
    }

    @Test func idNestedInsideApsIsIgnored() {
        // apns.ts spreads custom data at the top level, beside `aps` — not inside it.
        #expect(PushPayload.nudgeId(from: ["aps": ["nudge_id": 5]]) == nil)
    }

    @Test func parsesExactReceiveReplyPayloadShape() throws {
        // Mirrors `{ aps: {...}, ...data }` built by supabase/functions/_shared/apns.ts
        // with data = { nudge_id: nudgeId } from receive-reply.
        let json = """
        {"aps":{"alert":{"title":"Alice replied","body":"You got this"},"sound":"default"},"nudge_id":17}
        """
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let userInfo = try #require(object as? [AnyHashable: Any])
        #expect(PushPayload.nudgeId(from: userInfo) == 17)
    }
}

// MARK: - Push route parsing (5I)

@Suite("PushPayload route parsing")
@MainActor
struct PushPayloadRouteTests {

    private func userInfo(_ json: String) throws -> [AnyHashable: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(object as? [AnyHashable: Any])
    }

    // friend_accepted

    @Test func parsesExactFriendAcceptedPayloadShape() throws {
        // Mirrors `{ aps: {...}, ...data }` built by apns.ts with
        // data = { type: "friend_accepted", friend_id } from receive-reply's YES branch.
        let json = """
        {"aps":{"alert":{"title":"Alice accepted","body":"Alice agreed to be your Nudge friend. They'll get a text when you need a nudge."},"sound":"default"},"type":"friend_accepted","friend_id":23}
        """
        #expect(PushPayload.route(from: try userInfo(json)) == .friendAccepted(friendId: 23))
    }

    @Test func friendAcceptedAcceptsNumberAndNumericStringIds() {
        #expect(PushPayload.route(from: ["type": "friend_accepted", "friend_id": 5]) == .friendAccepted(friendId: 5))
        #expect(PushPayload.route(from: ["type": "friend_accepted", "friend_id": NSNumber(value: 6)]) == .friendAccepted(friendId: 6))
        #expect(PushPayload.route(from: ["type": "friend_accepted", "friend_id": "7"]) == .friendAccepted(friendId: 7))
        #expect(PushPayload.route(from: ["type": "friend_accepted", "friend_id": 8.0]) == .friendAccepted(friendId: 8))
    }

    @Test func friendAcceptedWithMissingIdRoutesNowhere() {
        #expect(PushPayload.route(from: ["type": "friend_accepted"]) == nil)
    }

    @Test func friendAcceptedWithInvalidIdRoutesNowhere() {
        let invalidIds: [Any] = [0, -1, "-1", "abc", "", 1.5, true, NSNull(), ["id": 1]]
        for bad in invalidIds {
            #expect(PushPayload.route(from: ["type": "friend_accepted", "friend_id": bad]) == nil)
        }
    }

    @Test func malformedFriendAcceptedDoesNotFallBackToNudgeId() {
        #expect(PushPayload.route(from: ["type": "friend_accepted", "friend_id": "x", "nudge_id": 17]) == nil)
    }

    @Test func friendAcceptedFieldsNestedInsideApsAreIgnored() {
        #expect(PushPayload.route(from: ["aps": ["type": "friend_accepted", "friend_id": 5] as [String: Any]]) == nil)
    }

    @Test func friendIdWithoutTypeRoutesNowhere() {
        #expect(PushPayload.route(from: ["friend_id": 5]) == nil)
    }

    @Test func unknownTypeRoutesNowhere() {
        #expect(PushPayload.route(from: ["type": "something_new", "friend_id": 5]) == nil)
        #expect(PushPayload.route(from: ["type": "FRIEND_ACCEPTED", "friend_id": 5]) == nil)
        #expect(PushPayload.route(from: ["aps": ["alert": "hi"]]) == nil)
        #expect(PushPayload.route(from: [:]) == nil)
    }

    // Reply pushes — unchanged behavior

    @Test func replyPayloadRoutesToNudgeReply() throws {
        let json = """
        {"aps":{"alert":{"title":"Message from Alice","body":"You got this"},"sound":"default"},"nudge_id":17}
        """
        #expect(PushPayload.route(from: try userInfo(json)) == .nudgeReply(nudgeId: 17))
    }

    @Test func replyRouteUsesTheSameNudgeIdParsing() {
        let samples: [Any] = [42, NSNumber(value: 7), "99", " 99 ", 12.0, "abc", 12.5, true, 0, -3, NSNull()]
        for raw in samples {
            let expected = PushPayload.nudgeId(from: ["nudge_id": raw]).map { PushRoute.nudgeReply(nudgeId: $0) }
            #expect(PushPayload.route(from: ["nudge_id": raw]) == expected)
        }
    }
}

// MARK: - PushRouter

@Suite("PushRouter")
@MainActor
struct PushRouterTests {

    @Test func startsWithNoPendingRoute() {
        #expect(PushRouter().pendingRoute == nil)
    }

    @Test func handleStoresPendingRoute() {
        let router = PushRouter()
        router.handle(.nudgeReply(nudgeId: 3))
        #expect(router.pendingRoute == .nudgeReply(nudgeId: 3))
    }

    @Test func consumeReturnsAndClearsPendingRoute() {
        let router = PushRouter()
        router.handle(.nudgeReply(nudgeId: 3))

        #expect(router.consumePendingRoute() == .nudgeReply(nudgeId: 3))
        #expect(router.pendingRoute == nil)
        #expect(router.consumePendingRoute() == nil)
    }

    @Test func consumeWhenEmptyReturnsNil() {
        #expect(PushRouter().consumePendingRoute() == nil)
    }

    @Test func laterTapReplacesEarlierPendingRoute() {
        let router = PushRouter()
        router.handle(.nudgeReply(nudgeId: 1))
        router.handle(.friendAccepted(friendId: 2))
        #expect(router.consumePendingRoute() == .friendAccepted(friendId: 2))
    }

    @Test func friendAcceptedRouteIsConsumedLikeAnyOther() {
        let router = PushRouter()
        router.handle(.friendAccepted(friendId: 9))

        #expect(router.consumePendingRoute() == .friendAccepted(friendId: 9))
        #expect(router.pendingRoute == nil)
    }

    @Test func resetClearsPendingRoute() {
        let router = PushRouter()
        router.handle(.friendAccepted(friendId: 1))
        router.reset()
        #expect(router.pendingRoute == nil)
    }

    @Test func everyRouteLandsOnTheFriendsTab() {
        #expect(AppTab.destination(for: .friendAccepted(friendId: 4)) == .friends)
        #expect(AppTab.destination(for: .nudgeReply(nudgeId: 4)) == .friends)
    }
}

// MARK: - PushRegistration

@Suite("PushRegistration")
@MainActor
struct PushRegistrationTests {

    @Test func registersForGrantedStatuses() {
        #expect(PushRegistration.shouldRegister(for: .authorized))
        #expect(PushRegistration.shouldRegister(for: .provisional))
        #expect(PushRegistration.shouldRegister(for: .ephemeral))
    }

    @Test func doesNotRegisterForUngrantedStatuses() {
        #expect(!PushRegistration.shouldRegister(for: .notDetermined))
        #expect(!PushRegistration.shouldRegister(for: .denied))
    }
}

// MARK: - PushTokenManager

@MainActor
private final class MockDeviceTokenService: DeviceTokenServiceProtocol {
    var registerError: Error? = nil
    var deleteError: Error? = nil
    /// When set, `deleteToken` sleeps this long (cancellably) before returning.
    var deleteDelay: Duration? = nil
    private(set) var registered: [(token: String, userId: UUID)] = []
    private(set) var deleted: [(token: String, userId: UUID)] = []

    func registerToken(_ token: String, userId: UUID) async throws {
        if let registerError { throw registerError }
        registered.append((token, userId))
    }

    func deleteToken(_ token: String, userId: UUID) async throws {
        deleted.append((token, userId))
        if let deleteDelay { try await Task.sleep(for: deleteDelay) }
        if let deleteError { throw deleteError }
    }
}

@Suite("PushTokenManager")
@MainActor
struct PushTokenManagerTests {

    private let defaults: UserDefaults
    private let mock = MockDeviceTokenService()

    init() {
        let suite = "PushTokenManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeManager(timeout: Duration = .seconds(5)) -> PushTokenManager {
        PushTokenManager(service: mock, defaults: defaults, deleteTimeout: timeout)
    }

    @Test func tokenBeforeSignInIsStoredButNotUploaded() async {
        let manager = makeManager()

        await manager.didReceiveDeviceToken("aa11")

        #expect(manager.currentToken == "aa11")
        #expect(mock.registered.isEmpty)
    }

    @Test func tokenReceivedBeforeSignInUploadsOnSignIn() async {
        let manager = makeManager()
        let userId = UUID()

        await manager.didReceiveDeviceToken("aa11")
        await manager.userDidSignIn(userId: userId)

        #expect(mock.registered.count == 1)
        #expect(mock.registered.first?.token == "aa11")
        #expect(mock.registered.first?.userId == userId)
    }

    @Test func tokenReceivedAfterSignInUploadsImmediately() async {
        let manager = makeManager()
        let userId = UUID()

        await manager.userDidSignIn(userId: userId)
        #expect(mock.registered.isEmpty)   // nothing to upload yet

        await manager.didReceiveDeviceToken("bb22")
        #expect(mock.registered.count == 1)
        #expect(mock.registered.first?.token == "bb22")
    }

    @Test func sameTokenAndUserUploadsOnlyOncePerSession() async {
        let manager = makeManager()
        let userId = UUID()

        await manager.userDidSignIn(userId: userId)
        await manager.didReceiveDeviceToken("cc33")
        await manager.didReceiveDeviceToken("cc33")
        await manager.userDidSignIn(userId: userId)

        #expect(mock.registered.count == 1)
    }

    @Test func rotatedTokenIsUploaded() async {
        let manager = makeManager()
        await manager.userDidSignIn(userId: UUID())

        await manager.didReceiveDeviceToken("old")
        await manager.didReceiveDeviceToken("new")

        #expect(mock.registered.map(\.token) == ["old", "new"])
        #expect(manager.currentToken == "new")
    }

    @Test func persistedTokenFromPreviousLaunchUploadsOnSignIn() async {
        await makeManager().didReceiveDeviceToken("persisted")

        let relaunched = makeManager()
        await relaunched.userDidSignIn(userId: UUID())

        #expect(mock.registered.map(\.token) == ["persisted"])
    }

    @Test func failedUploadIsRetriedOnNextTrigger() async {
        let manager = makeManager()
        mock.registerError = URLError(.notConnectedToInternet)
        await manager.userDidSignIn(userId: UUID())
        await manager.didReceiveDeviceToken("dd44")
        #expect(mock.registered.isEmpty)

        mock.registerError = nil
        await manager.didReceiveDeviceToken("dd44")

        #expect(mock.registered.count == 1)
    }

    @Test func differentUserSignInUploadsAgain() async {
        let manager = makeManager()
        await manager.didReceiveDeviceToken("ee55")
        await manager.userDidSignIn(userId: UUID())
        manager.userDidSignOut()
        await manager.userDidSignIn(userId: UUID())

        #expect(mock.registered.count == 2)
    }

    @Test func tokenAfterSignOutIsNotUploaded() async {
        let manager = makeManager()
        await manager.userDidSignIn(userId: UUID())
        manager.userDidSignOut()

        await manager.didReceiveDeviceToken("ff66")

        #expect(mock.registered.isEmpty)
    }

    @Test func unregisterDeletesThisDevicesTokenForUser() async {
        let manager = makeManager()
        let userId = UUID()
        await manager.didReceiveDeviceToken("gg77")
        await manager.userDidSignIn(userId: userId)

        await manager.unregisterDevice(userId: userId)

        #expect(mock.deleted.count == 1)
        #expect(mock.deleted.first?.token == "gg77")
        #expect(mock.deleted.first?.userId == userId)
        // The token belongs to the device, not the user — keep it for the next sign-in.
        #expect(manager.currentToken == "gg77")
    }

    @Test func unregisterWithoutTokenDoesNothing() async {
        let manager = makeManager()
        await manager.unregisterDevice(userId: UUID())
        #expect(mock.deleted.isEmpty)
    }

    @Test func unregisterSwallowsDeleteFailure() async {
        let manager = makeManager()
        mock.deleteError = URLError(.notConnectedToInternet)
        await manager.didReceiveDeviceToken("hh88")

        await manager.unregisterDevice(userId: UUID())   // must not throw or hang

        #expect(mock.deleted.count == 1)
    }

    @Test func unregisterGivesUpAfterTimeout() async {
        let manager = makeManager(timeout: .milliseconds(50))
        mock.deleteDelay = .seconds(30)
        await manager.didReceiveDeviceToken("ii99")

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await manager.unregisterDevice(userId: UUID())
        }

        #expect(elapsed < .seconds(5))
    }

    @Test func signInAfterUnregisterUploadsAgain() async {
        let manager = makeManager()
        let userId = UUID()
        await manager.didReceiveDeviceToken("jj00")
        await manager.userDidSignIn(userId: userId)
        await manager.unregisterDevice(userId: userId)
        manager.userDidSignOut()

        await manager.userDidSignIn(userId: userId)

        #expect(mock.registered.count == 2)
    }
}

// MARK: - Deep-link resolution (SocialViewModel)

@MainActor
private final class DeepLinkMockFriendService: FriendServiceProtocol {
    var friendsToReturn: [Friend] = []
    /// nudge id → friend id. Missing key = nudge not visible to this user (RLS) / not found.
    var friendIdByNudgeId: [Int: Int] = [:]
    var lookupError: Error? = nil
    private(set) var fetchFriendsCallCount = 0
    private(set) var lookedUpNudgeIds: [Int] = []

    func fetchFriends(userId: UUID) async throws -> [Friend] {
        fetchFriendsCallCount += 1
        return friendsToReturn
    }

    func addFriend(userId: UUID, name: String, phoneNumber: String) async throws {}
    func deleteFriend(id: Int) async throws {}
    func updateFriendName(id: Int, name: String) async throws {}
    func fetchNudgeHistory(friendId: Int) async throws -> [Nudge] { [] }

    func fetchFriendId(forNudgeId nudgeId: Int) async throws -> Int? {
        lookedUpNudgeIds.append(nudgeId)
        if let lookupError { throw lookupError }
        return friendIdByNudgeId[nudgeId]
    }
}

@Suite("SocialViewModel deep link")
@MainActor
struct SocialDeepLinkTests {

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

    @Test func resolvesNudgeToLoadedFriend() async {
        let mock = DeepLinkMockFriendService()
        mock.friendsToReturn = [makeFriend(id: 1), makeFriend(id: 2)]
        mock.friendIdByNudgeId = [50: 2]
        let vm = SocialViewModel(friendService: mock, realtimeService: MockFriendRealtimeService())
        await vm.load(userId: UUID())

        let friend = await vm.friendForNudge(id: 50, userId: UUID())

        #expect(friend?.id == 2)
        #expect(mock.lookedUpNudgeIds == [50])
        #expect(mock.fetchFriendsCallCount == 1)   // no refetch when already loaded
    }

    @Test func unknownNudgeResolvesToNilWithoutError() async {
        let mock = DeepLinkMockFriendService()
        mock.friendsToReturn = [makeFriend(id: 1)]
        let vm = SocialViewModel(friendService: mock, realtimeService: MockFriendRealtimeService())
        await vm.load(userId: UUID())

        let friend = await vm.friendForNudge(id: 999, userId: UUID())

        #expect(friend == nil)
        #expect(vm.error == nil)
    }

    @Test func lookupFailureResolvesToNilWithoutError() async {
        let mock = DeepLinkMockFriendService()
        mock.friendsToReturn = [makeFriend(id: 1)]
        mock.lookupError = URLError(.notConnectedToInternet)
        let vm = SocialViewModel(friendService: mock, realtimeService: MockFriendRealtimeService())
        await vm.load(userId: UUID())

        let friend = await vm.friendForNudge(id: 50, userId: UUID())

        #expect(friend == nil)
        #expect(vm.error == nil)
    }

    @Test func refetchesFriendsOnceWhenFriendNotInLoadedList() async {
        let mock = DeepLinkMockFriendService()
        mock.friendIdByNudgeId = [50: 3]
        let vm = SocialViewModel(friendService: mock, realtimeService: MockFriendRealtimeService())
        await vm.load(userId: UUID())          // empty list
        mock.friendsToReturn = [makeFriend(id: 3)]

        let friend = await vm.friendForNudge(id: 50, userId: UUID())

        #expect(friend?.id == 3)
        #expect(mock.fetchFriendsCallCount == 2)
        #expect(vm.friends.map(\.id) == [3])
    }

    @Test func friendMissingAfterRefetchResolvesToNil() async {
        let mock = DeepLinkMockFriendService()
        mock.friendsToReturn = [makeFriend(id: 1)]
        mock.friendIdByNudgeId = [50: 3]       // friend 3 deleted / blocked
        let vm = SocialViewModel(friendService: mock, realtimeService: MockFriendRealtimeService())
        await vm.load(userId: UUID())

        let friend = await vm.friendForNudge(id: 50, userId: UUID())

        #expect(friend == nil)
        #expect(vm.error == nil)
    }

    @Test func nonAcceptedFriendResolvesToNil() async {
        let mock = DeepLinkMockFriendService()
        mock.friendsToReturn = [makeFriend(id: 4, status: .pending)]
        mock.friendIdByNudgeId = [50: 4]
        let vm = SocialViewModel(friendService: mock, realtimeService: MockFriendRealtimeService())
        await vm.load(userId: UUID())

        #expect(await vm.friendForNudge(id: 50, userId: UUID()) == nil)
    }
}

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

// MARK: - PushRouter

@Suite("PushRouter")
@MainActor
struct PushRouterTests {

    @Test func startsWithNoPendingNudge() {
        #expect(PushRouter().pendingNudgeId == nil)
    }

    @Test func handleNudgeTapStoresPendingId() {
        let router = PushRouter()
        router.handleNudgeTap(nudgeId: 3)
        #expect(router.pendingNudgeId == 3)
    }

    @Test func consumeReturnsAndClearsPendingId() {
        let router = PushRouter()
        router.handleNudgeTap(nudgeId: 3)

        #expect(router.consumePendingNudgeId() == 3)
        #expect(router.pendingNudgeId == nil)
        #expect(router.consumePendingNudgeId() == nil)
    }

    @Test func consumeWhenEmptyReturnsNil() {
        #expect(PushRouter().consumePendingNudgeId() == nil)
    }

    @Test func laterTapReplacesEarlierPendingId() {
        let router = PushRouter()
        router.handleNudgeTap(nudgeId: 1)
        router.handleNudgeTap(nudgeId: 2)
        #expect(router.consumePendingNudgeId() == 2)
    }

    @Test func resetClearsPendingId() {
        let router = PushRouter()
        router.handleNudgeTap(nudgeId: 1)
        router.reset()
        #expect(router.pendingNudgeId == nil)
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
        let vm = SocialViewModel(friendService: mock)
        await vm.load(userId: UUID())

        let friend = await vm.friendForNudge(id: 50, userId: UUID())

        #expect(friend?.id == 2)
        #expect(mock.lookedUpNudgeIds == [50])
        #expect(mock.fetchFriendsCallCount == 1)   // no refetch when already loaded
    }

    @Test func unknownNudgeResolvesToNilWithoutError() async {
        let mock = DeepLinkMockFriendService()
        mock.friendsToReturn = [makeFriend(id: 1)]
        let vm = SocialViewModel(friendService: mock)
        await vm.load(userId: UUID())

        let friend = await vm.friendForNudge(id: 999, userId: UUID())

        #expect(friend == nil)
        #expect(vm.error == nil)
    }

    @Test func lookupFailureResolvesToNilWithoutError() async {
        let mock = DeepLinkMockFriendService()
        mock.friendsToReturn = [makeFriend(id: 1)]
        mock.lookupError = URLError(.notConnectedToInternet)
        let vm = SocialViewModel(friendService: mock)
        await vm.load(userId: UUID())

        let friend = await vm.friendForNudge(id: 50, userId: UUID())

        #expect(friend == nil)
        #expect(vm.error == nil)
    }

    @Test func refetchesFriendsOnceWhenFriendNotInLoadedList() async {
        let mock = DeepLinkMockFriendService()
        mock.friendIdByNudgeId = [50: 3]
        let vm = SocialViewModel(friendService: mock)
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
        let vm = SocialViewModel(friendService: mock)
        await vm.load(userId: UUID())

        let friend = await vm.friendForNudge(id: 50, userId: UUID())

        #expect(friend == nil)
        #expect(vm.error == nil)
    }

    @Test func nonAcceptedFriendResolvesToNil() async {
        let mock = DeepLinkMockFriendService()
        mock.friendsToReturn = [makeFriend(id: 4, status: .pending)]
        mock.friendIdByNudgeId = [50: 4]
        let vm = SocialViewModel(friendService: mock)
        await vm.load(userId: UUID())

        #expect(await vm.friendForNudge(id: 50, userId: UUID()) == nil)
    }
}

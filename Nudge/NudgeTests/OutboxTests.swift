import Testing
import Foundation
import Supabase
@testable import Nudge

// Generic outbox of pending server writes (docs/specs/onboarding-progress.md §3.2).
// Storage, network reachability, the signed-in user and the clock are all injected, so
// nothing here touches the network or `UserDefaults.standard`.

// MARK: - Fakes

@MainActor
final class InMemoryOutboxStorage: OutboxStorage {
    var writes: [PendingWrite] = []
    private(set) var saveCount = 0
    func loadWrites() -> [PendingWrite] { writes }
    func saveWrites(_ writes: [PendingWrite]) {
        self.writes = writes
        saveCount += 1
    }
}

@MainActor
final class FakeNetwork: NetworkStatusProviding {
    var isOnline: Bool
    private var handlers: [@MainActor () -> Void] = []

    init(isOnline: Bool) { self.isOnline = isOnline }

    func addReachabilityHandler(_ handler: @escaping @MainActor () -> Void) {
        handlers.append(handler)
    }

    /// The path went from unsatisfied to satisfied.
    func becomeReachable() {
        isOnline = true
        handlers.forEach { $0() }
    }
}

/// A fixed, steppable clock.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval = 1) { now = now.addingTimeInterval(seconds) }
    var provider: () -> Date { { [unowned self] in now } }
}

private struct NotePayload: Codable, Equatable { let text: String }

private enum TestKinds {
    static let note = OutboxKind<NotePayload>(name: "note", coalescing: .none)
    static let latest = OutboxKind<NotePayload>(name: "latest", coalescing: .replacePending)
    static let once = OutboxKind<NotePayload>(name: "once", coalescing: .oncePending)
}

/// Records handler calls; can throw per call and hold a call open.
@MainActor
private final class HandlerRecorder {
    struct Call: Equatable { let kind: String; let userId: UUID; let text: String }
    private(set) var calls: [Call] = []
    /// Errors to throw, consumed in order (nil = succeed).
    var errors: [Error?] = []
    var holdCalls = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func handler(_ kind: String) -> @MainActor (UUID, NotePayload) async throws -> Void {
        { [self] userId, payload in
            calls.append(Call(kind: kind, userId: userId, text: payload.text))
            if holdCalls { await withCheckedContinuation { held.append($0) } }
            if !errors.isEmpty, let error = errors.removeFirst() { throw error }
        }
    }

    func releaseAll() {
        let pending = held
        held = []
        pending.forEach { $0.resume() }
    }

    var texts: [String] { calls.map(\.text) }
}

private func httpError(_ status: Int) -> HTTPError {
    HTTPError(
        data: Data(),
        response: HTTPURLResponse(url: URL(string: "https://example.supabase.co/rest/v1/profile")!,
                                  statusCode: status, httpVersion: nil, headerFields: nil)!
    )
}

// MARK: - Outbox

@Suite("Outbox")
@MainActor
struct OutboxTests {

    private let userA = UUID()
    private let userB = UUID()
    private let storage = InMemoryOutboxStorage()
    private let clock = TestClock()
    private let recorder = HandlerRecorder()

    private func makeOutbox(online: Bool = false, currentUser: UUID? = nil) -> (Outbox, FakeNetwork) {
        let network = FakeNetwork(isOnline: online)
        let user = currentUser ?? userA
        let outbox = Outbox(storage: storage, network: network, currentUserId: { user }, now: clock.provider)
        outbox.register(TestKinds.note, handler: recorder.handler("note"))
        outbox.register(TestKinds.latest, handler: recorder.handler("latest"))
        outbox.register(TestKinds.once, handler: recorder.handler("once"))
        return (outbox, network)
    }

    // MARK: Enqueue + persistence

    @Test func enqueuePersistsTheWrite() throws {
        let (outbox, _) = makeOutbox()
        outbox.enqueue(TestKinds.note, payload: NotePayload(text: "a"), for: userA)

        #expect(storage.writes.count == 1)
        let write = try #require(storage.writes.first)
        #expect(write.userId == userA)
        #expect(write.kind == "note")
        #expect(write.attempts == 0)
        #expect(write.createdAt == clock.now)
        #expect(try JSONDecoder().decode(NotePayload.self, from: write.payload) == NotePayload(text: "a"))
    }

    @Test func aNewOutboxReadsTheQueueBackFromStorage() {
        let (first, _) = makeOutbox()
        first.enqueue(TestKinds.note, payload: NotePayload(text: "a"), for: userA)

        let (second, _) = makeOutbox()
        #expect(second.pendingWrites(for: userA).count == 1)
    }

    @Test func pendingWriteRoundTripsThroughJSON() throws {
        let write = PendingWrite(id: UUID(), userId: userA, kind: "note", payload: Data("{}".utf8),
                                 createdAt: clock.now, attempts: 2)
        let decoded = try JSONDecoder().decode(PendingWrite.self, from: JSONEncoder().encode(write))
        #expect(decoded == write)
    }

    @Test func enqueueWhileOfflineDoesNotFlush() async {
        let (outbox, _) = makeOutbox(online: false)
        outbox.enqueue(TestKinds.note, payload: NotePayload(text: "a"), for: userA)
        await outbox.currentFlush?.value
        #expect(recorder.calls.isEmpty)
        #expect(outbox.pendingWrites(for: userA).count == 1)
    }

    @Test func enqueueWhileOnlineFlushesRightAway() async {
        let (outbox, _) = makeOutbox(online: true)
        outbox.enqueue(TestKinds.note, payload: NotePayload(text: "a"), for: userA)
        await outbox.currentFlush?.value
        #expect(recorder.texts == ["a"])
        #expect(outbox.pendingWrites(for: userA).isEmpty)
    }

    @Test func becomingReachableFlushes() async {
        let (outbox, network) = makeOutbox(online: false)
        outbox.enqueue(TestKinds.note, payload: NotePayload(text: "a"), for: userA)
        network.becomeReachable()
        await outbox.currentFlush?.value
        #expect(recorder.texts == ["a"])
    }

    // MARK: Order

    @Test func flushSendsOldestFirstAndRemovesEachAcceptedWrite() async {
        let (outbox, _) = makeOutbox()
        for text in ["1", "2", "3"] {
            outbox.enqueue(TestKinds.note, payload: NotePayload(text: text), for: userA)
            clock.advance()
        }
        await outbox.flush()?.value
        #expect(recorder.texts == ["1", "2", "3"])
        #expect(storage.writes.isEmpty)
    }

    // MARK: Coalescing

    @Test func replacePendingKeepsOnlyTheNewestPayload() async {
        let (outbox, _) = makeOutbox()
        outbox.enqueue(TestKinds.latest, payload: NotePayload(text: "old"), for: userA)
        outbox.enqueue(TestKinds.note, payload: NotePayload(text: "between"), for: userA)
        outbox.enqueue(TestKinds.latest, payload: NotePayload(text: "new"), for: userA)

        #expect(outbox.pendingWrites(for: userA).count == 2)
        await outbox.flush()?.value
        #expect(recorder.texts == ["new", "between"])
    }

    @Test func replacePendingDoesNotTouchAnotherUsersWrite() {
        let (outbox, _) = makeOutbox()
        outbox.enqueue(TestKinds.latest, payload: NotePayload(text: "a"), for: userA)
        outbox.enqueue(TestKinds.latest, payload: NotePayload(text: "b"), for: userB)
        #expect(outbox.pendingWrites(for: userA).count == 1)
        #expect(outbox.pendingWrites(for: userB).count == 1)
    }

    @Test func oncePendingIsQueuedAtMostOnce() {
        let (outbox, _) = makeOutbox()
        outbox.enqueue(TestKinds.once, payload: NotePayload(text: "1"), for: userA)
        outbox.enqueue(TestKinds.once, payload: NotePayload(text: "2"), for: userA)
        #expect(outbox.pendingWrites(for: userA).count == 1)
        #expect(outbox.hasPending(TestKinds.once, for: userA))
        #expect(!outbox.hasPending(TestKinds.once, for: userB))
    }

    @Test func noCoalescingKeepsEveryWrite() {
        let (outbox, _) = makeOutbox()
        outbox.enqueue(TestKinds.note, payload: NotePayload(text: "1"), for: userA)
        outbox.enqueue(TestKinds.note, payload: NotePayload(text: "1"), for: userA)
        #expect(outbox.pendingWrites(for: userA).count == 2)
    }

    // MARK: Errors

    @Test(arguments: [
        URLError(.notConnectedToInternet) as Error,
        URLError(.timedOut) as Error,
        httpError(500) as Error,
        httpError(503) as Error,
        httpError(429) as Error,
    ])
    func retryableErrorStopsTheFlushAndKeepsOrder(error: Error) async {
        let (outbox, _) = makeOutbox()
        for text in ["1", "2", "3"] {
            outbox.enqueue(TestKinds.note, payload: NotePayload(text: text), for: userA)
        }
        recorder.errors = [nil, error]

        await outbox.flush()?.value

        #expect(recorder.texts == ["1", "2"])   // "3" was never attempted
        let remaining = outbox.pendingWrites(for: userA)
        #expect(remaining.compactMap { try? JSONDecoder().decode(NotePayload.self, from: $0.payload).text } == ["2", "3"])
        #expect(remaining.first?.attempts == 1)
    }

    @Test func retriedWriteIsSentAgainOnTheNextTrigger() async {
        let (outbox, _) = makeOutbox()
        outbox.enqueue(TestKinds.note, payload: NotePayload(text: "1"), for: userA)
        recorder.errors = [URLError(.networkConnectionLost)]
        await outbox.flush()?.value
        await outbox.flush()?.value
        #expect(recorder.texts == ["1", "1"])
        #expect(outbox.pendingWrites(for: userA).isEmpty)
    }

    @Test(arguments: [
        httpError(400) as Error,
        httpError(404) as Error,
        httpError(409) as Error,
        PostgrestError(code: "23514", message: "violates check constraint") as Error,
    ])
    func permanentClientErrorDropsTheWriteAndContinues(error: Error) async {
        let (outbox, _) = makeOutbox()
        for text in ["1", "2", "3"] {
            outbox.enqueue(TestKinds.note, payload: NotePayload(text: text), for: userA)
        }
        recorder.errors = [nil, error, nil]

        await outbox.flush()?.value

        #expect(recorder.texts == ["1", "2", "3"])
        #expect(outbox.pendingWrites(for: userA).isEmpty)
    }

    // MARK: Single flight

    @Test func onlyOneFlushRunsAtATime() async {
        let (outbox, _) = makeOutbox()
        outbox.enqueue(TestKinds.note, payload: NotePayload(text: "1"), for: userA)
        recorder.holdCalls = true

        let first = outbox.flush()
        await Task.yield()
        let second = outbox.flush()
        #expect(outbox.isFlushing)

        recorder.releaseAll()
        await first?.value
        await second?.value

        #expect(recorder.texts == ["1"])
        #expect(!outbox.isFlushing)
    }

    @Test func writeEnqueuedDuringAFlushIsSentByThatFlush() async {
        let (outbox, _) = makeOutbox()
        outbox.enqueue(TestKinds.note, payload: NotePayload(text: "1"), for: userA)
        recorder.holdCalls = true
        let flush = outbox.flush()
        await Task.yield()
        outbox.enqueue(TestKinds.note, payload: NotePayload(text: "2"), for: userA)
        recorder.holdCalls = false
        recorder.releaseAll()
        await flush?.value
        #expect(recorder.texts == ["1", "2"])
    }

    @Test func replacingTheWriteBeingSentQueuesTheNewPayloadInstead() async {
        let (outbox, _) = makeOutbox()
        outbox.enqueue(TestKinds.latest, payload: NotePayload(text: "old"), for: userA)
        recorder.holdCalls = true
        let flush = outbox.flush()
        await Task.yield()
        #expect(recorder.texts == ["old"])   // "old" is on the wire

        outbox.enqueue(TestKinds.latest, payload: NotePayload(text: "new"), for: userA)
        recorder.holdCalls = false
        recorder.releaseAll()
        await flush?.value

        #expect(recorder.texts == ["old", "new"])
        #expect(outbox.pendingWrites(for: userA).isEmpty)
    }

    // MARK: Per-user isolation

    @Test func flushSendsOnlyTheSignedInUsersWrites() async {
        let (outbox, _) = makeOutbox(currentUser: userA)
        outbox.enqueue(TestKinds.note, payload: NotePayload(text: "b"), for: userB)
        outbox.enqueue(TestKinds.note, payload: NotePayload(text: "a"), for: userA)

        await outbox.flush()?.value

        #expect(recorder.calls == [.init(kind: "note", userId: userA, text: "a")])
        #expect(outbox.pendingWrites(for: userB).count == 1)
    }

    @Test func noSignedInUserFlushesNothing() async {
        let network = FakeNetwork(isOnline: true)
        let outbox = Outbox(storage: storage, network: network, currentUserId: { nil }, now: clock.provider)
        outbox.register(TestKinds.note, handler: recorder.handler("note"))
        outbox.enqueue(TestKinds.note, payload: NotePayload(text: "a"), for: userA)
        #expect(outbox.flush() == nil)
        await outbox.currentFlush?.value
        #expect(recorder.calls.isEmpty)
    }

    @Test func removeAllClearsOnlyThatUser() {
        let (outbox, _) = makeOutbox()
        outbox.enqueue(TestKinds.note, payload: NotePayload(text: "a"), for: userA)
        outbox.enqueue(TestKinds.note, payload: NotePayload(text: "b"), for: userB)
        outbox.removeAll(for: userA)
        #expect(outbox.pendingWrites(for: userA).isEmpty)
        #expect(outbox.pendingWrites(for: userB).count == 1)
        #expect(storage.writes.count == 1)
    }

    @Test func writeWithNoRegisteredHandlerStaysQueued() async {
        let network = FakeNetwork(isOnline: false)
        let outbox = Outbox(storage: storage, network: network, currentUserId: { [userA] in userA }, now: clock.provider)
        outbox.enqueue(TestKinds.note, payload: NotePayload(text: "a"), for: userA)
        await outbox.flush()?.value
        #expect(outbox.pendingWrites(for: userA).count == 1)
    }

    @Test func revisionChangesOnEveryQueueMutation() async {
        let (outbox, _) = makeOutbox()
        let start = outbox.revision
        outbox.enqueue(TestKinds.note, payload: NotePayload(text: "a"), for: userA)
        let afterEnqueue = outbox.revision
        #expect(afterEnqueue != start)
        await outbox.flush()?.value
        #expect(outbox.revision != afterEnqueue)
    }
}

// MARK: - Error classification

@Suite("OutboxErrorClassifier")
@MainActor
struct OutboxErrorClassifierTests {

    @Test func networkErrorsRetry() {
        #expect(OutboxErrorClassifier.disposition(for: URLError(.notConnectedToInternet)) == .retryLater)
        #expect(OutboxErrorClassifier.disposition(for: URLError(.cannotFindHost)) == .retryLater)
        #expect(OutboxErrorClassifier.disposition(for: CancellationError()) == .retryLater)
    }

    @Test func httpStatusDisposition() {
        for status in [408, 429, 500, 502, 503, 504, 401] {
            #expect(OutboxErrorClassifier.disposition(forHTTPStatus: status) == .retryLater, "status \(status)")
        }
        for status in [400, 403, 404, 409, 422] {
            #expect(OutboxErrorClassifier.disposition(forHTTPStatus: status) == .drop, "status \(status)")
        }
    }

    @Test func postgrestCodes() {
        // Data / constraint / syntax-or-privilege errors are permanent.
        for code in ["23514", "23505", "23502", "22001", "42703", "42501", "PGRST204", "PGRST116"] {
            #expect(OutboxErrorClassifier.disposition(for: PostgrestError(code: code, message: "x")) == .drop, "code \(code)")
        }
        // Connection, resource and JWT errors are temporary.
        for code in ["08006", "53300", "57014", "40001", "PGRST000", "PGRST301", "PGRST303"] {
            #expect(OutboxErrorClassifier.disposition(for: PostgrestError(code: code, message: "x")) == .retryLater, "code \(code)")
        }
        #expect(OutboxErrorClassifier.disposition(for: PostgrestError(message: "no code")) == .retryLater)
    }

    @Test func explicitHandlerErrorsWin() {
        #expect(OutboxErrorClassifier.disposition(for: OutboxWriteError.permanent) == .drop)
        #expect(OutboxErrorClassifier.disposition(for: OutboxWriteError.transient) == .retryLater)
    }

    @Test func unknownErrorsRetry() {
        struct Weird: Error {}
        #expect(OutboxErrorClassifier.disposition(for: Weird()) == .retryLater)
    }
}

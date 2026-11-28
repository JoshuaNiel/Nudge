import Foundation
import Supabase
import os

// A small, generic queue of pending server writes, persisted on the device
// (docs/specs/onboarding-progress.md §3.2). The foundation for offline-first writes:
// a feature applies its change locally, enqueues the write, and moves on. The outbox sends it
// when the network allows.
//
// A feature plugs in by declaring an `OutboxKind<Payload>` (name + coalescing rule) and
// registering a handler for it. The queue itself knows nothing about any kind.

// MARK: - Model

/// One queued server write. `payload` is the kind's JSON-encoded payload.
struct PendingWrite: Codable, Equatable, Identifiable {
    let id: UUID
    let userId: UUID
    let kind: String
    var payload: Data
    let createdAt: Date
    var attempts: Int
}

/// How a newly enqueued write combines with one of the same kind already queued for the user.
enum OutboxCoalescing: Equatable {
    /// Every write is kept.
    case none
    /// The new payload replaces the queued one (in its queue position); e.g. "latest value wins".
    case replacePending
    /// At most one is queued; later enqueues are ignored while one is pending.
    case oncePending
}

/// A kind of write. `Payload` is what the handler receives.
struct OutboxKind<Payload: Codable> {
    let name: String
    let coalescing: OutboxCoalescing
}

/// Persists the queue in order (oldest first).
protocol OutboxStorage: AnyObject {
    func loadWrites() -> [PendingWrite]
    func saveWrites(_ writes: [PendingWrite])
}

/// The production storage: one JSON array in `UserDefaults.standard`.
final class UserDefaultsOutboxStorage: OutboxStorage {
    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "Outbox")

    private let defaults: UserDefaults
    private let key: String

    init() {
        self.defaults = .standard
        self.key = AppStorageKeys.outbox
    }

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func loadWrites() -> [PendingWrite] {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([PendingWrite].self, from: data)
        } catch {
            Self.logger.error("outbox storage unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func saveWrites(_ writes: [PendingWrite]) {
        guard let data = try? JSONEncoder().encode(writes) else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: - Error classification

/// Handlers can throw these to classify a failure explicitly.
enum OutboxWriteError: Error {
    /// Retry on the next trigger.
    case transient
    /// The server will never accept this write; drop it.
    case permanent
}

enum OutboxDisposition: Equatable {
    /// Stop the flush, keep the write (and the queue order), retry on the next trigger.
    case retryLater
    /// Drop this write, log it, and continue with the next.
    case drop
}

/// Network / 5xx / 429 (and auth-token) failures are temporary; other 4xx are permanent.
/// Unknown errors are treated as temporary so a write is never lost to a misclassification.
enum OutboxErrorClassifier {

    static func disposition(for error: Error) -> OutboxDisposition {
        if let explicit = error as? OutboxWriteError {
            return explicit == .permanent ? .drop : .retryLater
        }
        if error is URLError || error is CancellationError { return .retryLater }
        if let http = error as? HTTPError {
            return disposition(forHTTPStatus: http.response.statusCode)
        }
        if let postgrest = error as? PostgrestError {
            return disposition(forPostgrestCode: postgrest.code)
        }
        return .retryLater
    }

    static func disposition(forHTTPStatus status: Int) -> OutboxDisposition {
        switch status {
        case 401, 408, 429: return .retryLater   // expired token (refreshes), timeout, rate limit
        case 400..<500: return .drop
        default: return .retryLater               // 5xx and anything unexpected
        }
    }

    /// `PostgrestError` carries the Postgres SQLSTATE or PostgREST code, not the HTTP status.
    static func disposition(forPostgrestCode code: String?) -> OutboxDisposition {
        guard let code, !code.isEmpty else { return .retryLater }
        if code.hasPrefix("PGRST") {
            // PGRST0xx: database connection (503/504). PGRST3xx: JWT (401).
            // PGRST1xx / PGRST2xx: request / schema-cache errors (4xx) — permanent.
            let group = code.dropFirst(5).first
            return group == "1" || group == "2" ? .drop : .retryLater
        }
        switch code.prefix(2) {
        case "22", "23", "42": return .drop     // data exception, constraint, syntax / privilege
        default: return .retryLater             // 08 connection, 40 rollback, 53 resources, 57 …
        }
    }
}

// MARK: - Outbox

/// Sends queued writes oldest first, for the signed-in user only.
///
/// Flush triggers: `flush()` from the app's foreground sync, the network becoming reachable,
/// and right after an enqueue while online. One flush at a time; a request during a flush
/// joins it (the running flush re-reads the queue, so writes enqueued meanwhile are sent).
@MainActor
final class Outbox {
    typealias Handler = @MainActor (_ userId: UUID, _ payload: Data) async throws -> Void

    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "Outbox")

    /// The app-wide outbox. Tests construct their own.
    static let shared = Outbox(
        storage: UserDefaultsOutboxStorage(),
        network: NetworkMonitor.shared,
        currentUserId: { supabase.auth.currentUser?.id },
        now: { Date() }
    )

    private let storage: OutboxStorage
    private let network: NetworkStatusProviding
    private let currentUserId: () -> UUID?
    private let now: () -> Date

    private var writes: [PendingWrite]
    private var handlers: [String: Handler] = [:]
    /// The write whose handler is running.
    private var inFlightWriteId: UUID?

    /// The running flush, if any (exposed so callers and tests can await it).
    private(set) var currentFlush: Task<Void, Never>?
    var isFlushing: Bool { currentFlush != nil }

    /// Bumped on every change to the queue (enqueue, accept, drop, clear). Lets a reader detect
    /// that the queue changed while it was waiting on the network.
    private(set) var revision = 0

    init(
        storage: OutboxStorage,
        network: NetworkStatusProviding,
        currentUserId: @escaping () -> UUID?,
        now: @escaping () -> Date
    ) {
        self.storage = storage
        self.network = network
        self.currentUserId = currentUserId
        self.now = now
        self.writes = storage.loadWrites()
        network.addReachabilityHandler { [weak self] in
            self?.flush()
        }
    }

    // MARK: Registration

    /// Registers (or replaces) the handler that sends writes of `kind`.
    func register<Payload: Codable>(
        _ kind: OutboxKind<Payload>,
        handler: @escaping @MainActor (_ userId: UUID, _ payload: Payload) async throws -> Void
    ) {
        handlers[kind.name] = { userId, data in
            let payload: Payload
            do {
                payload = try JSONDecoder().decode(Payload.self, from: data)
            } catch {
                // An undecodable payload can never be sent.
                throw OutboxWriteError.permanent
            }
            try await handler(userId, payload)
        }
    }

    // MARK: Queue

    /// Queues a write (applying the kind's coalescing rule) and, when online, flushes.
    func enqueue<Payload: Codable>(_ kind: OutboxKind<Payload>, payload: Payload, for userId: UUID) {
        guard let data = try? JSONEncoder().encode(payload) else {
            Self.logger.error("could not encode \(kind.name, privacy: .public) payload; not queued")
            return
        }
        // The write being sent right now can't be changed: its old payload is already on the
        // wire, and accepting it removes it by id. A replacement for it is queued as new.
        let existing = writes.firstIndex {
            $0.userId == userId && $0.kind == kind.name && $0.id != inFlightWriteId
        }
        let anyQueued = writes.contains { $0.userId == userId && $0.kind == kind.name }

        switch (kind.coalescing, existing) {
        case (.oncePending, _) where anyQueued:
            return
        case (.replacePending, .some(let index)):
            writes[index].payload = data
            writes[index].attempts = 0
        default:
            writes.append(PendingWrite(id: UUID(), userId: userId, kind: kind.name, payload: data,
                                       createdAt: now(), attempts: 0))
        }
        persist()

        if network.isOnline { flush() }
    }

    func pendingWrites(for userId: UUID) -> [PendingWrite] {
        writes.filter { $0.userId == userId }
    }

    func hasPending<Payload: Codable>(_ kind: OutboxKind<Payload>, for userId: UUID) -> Bool {
        writes.contains { $0.userId == userId && $0.kind == kind.name }
    }

    /// Deletes every queued write for `userId` (account deletion).
    func removeAll(for userId: UUID) {
        let before = writes.count
        writes.removeAll { $0.userId == userId }
        if writes.count != before { persist() }
    }

    // MARK: Flush

    /// Sends the signed-in user's writes, oldest first. Returns the running flush (started or
    /// joined), or `nil` when no user is signed in.
    @discardableResult
    func flush() -> Task<Void, Never>? {
        if let currentFlush { return currentFlush }
        guard let userId = currentUserId() else { return nil }
        let task = Task { [weak self] in
            await self?.send(for: userId)
            self?.currentFlush = nil
        }
        currentFlush = task
        return task
    }

    private func send(for userId: UUID) async {
        // Re-read the queue each round: writes may be enqueued while one is in flight.
        while let write = writes.first(where: { $0.userId == userId }) {
            guard let handler = handlers[write.kind] else {
                Self.logger.notice("no handler for \(write.kind, privacy: .public) yet; keeping it queued")
                return
            }
            inFlightWriteId = write.id
            defer { inFlightWriteId = nil }
            do {
                try await handler(userId, write.payload)
                remove(write.id)
            } catch {
                switch OutboxErrorClassifier.disposition(for: error) {
                case .retryLater:
                    if let index = writes.firstIndex(where: { $0.id == write.id }) {
                        writes[index].attempts += 1
                        persist()
                    }
                    Self.logger.notice("\(write.kind, privacy: .public) failed, will retry: \(error.localizedDescription, privacy: .public)")
                    return
                case .drop:
                    Self.logger.error("\(write.kind, privacy: .public) rejected by the server, dropped: \(error.localizedDescription, privacy: .public)")
                    remove(write.id)
                }
            }
        }
    }

    private func remove(_ id: UUID) {
        writes.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        revision &+= 1
        storage.saveWrites(writes)
    }
}

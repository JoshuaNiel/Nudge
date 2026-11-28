import Foundation
import Combine
import os

/// The signed-in user's onboarding progress (docs/specs/onboarding-progress.md §3).
///
/// Routing reads the **device copy first**; the server (`onboarding_status()`) refreshes it in
/// the background when online and never blocks the UI once a copy exists. Changes (profile
/// name, completion) are applied to the copy immediately and sent through the `Outbox`, so
/// onboarding works offline.
@MainActor
final class OnboardingProgressController: ObservableObject {

    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "Onboarding")

    /// The current user's device copy; `nil` while it is being seeded or when signed out.
    @Published private(set) var progress: OnboardingProgress?
    private(set) var userId: UUID?

    private let store: OnboardingProgressStoring
    private let outbox: Outbox
    private let server: OnboardingServerProtocol
    private let network: NetworkStatusProviding
    private let legacyDefaults: UserDefaults
    private let now: () -> Date
    /// How long a first launch (no device copy) waits for the server before falling back.
    private let seedTimeout: Duration

    /// Bumped on every local change, so a server answer that raced one is discarded.
    private var localRevision = 0
    private var refreshTask: Task<Void, Never>?

    // Production init — real store, shared outbox, Supabase, NWPathMonitor.
    convenience init() {
        self.init(
            store: OnboardingStore(),
            outbox: .shared,
            server: OnboardingService(),
            network: NetworkMonitor.shared,
            legacyDefaults: .standard,
            now: { Date() },
            seedTimeout: .seconds(10)
        )
    }

    // Test init — every dependency injected.
    init(
        store: OnboardingProgressStoring,
        outbox: Outbox,
        server: OnboardingServerProtocol,
        network: NetworkStatusProviding,
        legacyDefaults: UserDefaults,
        now: @escaping () -> Date,
        seedTimeout: Duration
    ) {
        self.store = store
        self.outbox = outbox
        self.server = server
        self.network = network
        self.legacyDefaults = legacyDefaults
        self.now = now
        self.seedTimeout = seedTimeout
        Self.registerOutboxHandlers(on: outbox, server: server)
    }

    /// The handlers capture only the server, never the controller.
    private static func registerOutboxHandlers(on outbox: Outbox, server: OnboardingServerProtocol) {
        outbox.register(OnboardingOutboxKinds.updateProfileName) { userId, payload in
            try await server.updateProfileName(userId: userId, firstName: payload.firstName, lastName: payload.lastName)
        }
        outbox.register(OnboardingOutboxKinds.markOnboardingCompleted) { userId, _ in
            try await server.markOnboardingCompleted(userId: userId)
        }
    }

    // MARK: - Seeding

    /// Loads (or seeds) the device copy for the signed-in user; `nil` on sign-out.
    func prepare(userId: UUID?) async {
        guard let userId else {
            reset()
            return
        }
        if userId == self.userId, progress != nil {
            await refresh()
            return
        }

        reset()
        self.userId = userId

        if let copy = store.load(for: userId) {
            apply(copy, for: userId)
            await refresh()
            return
        }

        if legacyDefaults.bool(forKey: AppStorageKeys.onboardingComplete) {
            // Finished onboarding on a build before per-account progress: treat as completed
            // and tell the server.
            apply(OnboardingProgress(completed: true, nextStep: nil, firstName: nil, lastName: nil,
                                     updatedAt: now()), for: userId)
            legacyDefaults.removeObject(forKey: AppStorageKeys.onboardingComplete)
            outbox.enqueue(OnboardingOutboxKinds.markOnboardingCompleted, payload: EmptyPayload(), for: userId)
            await refresh()
            return
        }

        if network.isOnline, let status = await fetchSeedStatus(userId: userId) {
            guard self.userId == userId else { return }
            apply(OnboardingMerge.merge(device: nil, server: status, hasQueuedNameUpdate: false, now: now()),
                  for: userId)
            return
        }

        // Offline (or the server didn't answer): start at profile setup. It works offline and
        // the next refresh merges whatever the server knows.
        guard self.userId == userId else { return }
        apply(OnboardingProgress(completed: false, nextStep: .profile, firstName: nil, lastName: nil,
                                 updatedAt: now()), for: userId)
    }

    private func fetchSeedStatus(userId: UUID) async -> OnboardingServerStatus? {
        let server = self.server
        let fetch = Task { try? await server.fetchStatus(userId: userId) }
        let timeout = seedTimeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            fetch.cancel()
        }
        let status = await fetch.value
        timer.cancel()
        if status == nil { Self.logger.notice("onboarding status unavailable on first launch; starting at profile setup") }
        return status
    }

    // MARK: - Refresh

    /// Sends queued writes, then merges the server's answer into the device copy. Skipped
    /// offline. One at a time; a call during a refresh joins it.
    func refresh() async {
        guard let userId, network.isOnline else { return }
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await performRefresh(userId: userId) }
        refreshTask = task
        await task.value
        if refreshTask == task { refreshTask = nil }
    }

    private func performRefresh(userId: UUID) async {
        // Writes first, so the server answer includes them.
        await outbox.flush()?.value

        let outboxRevision = outbox.revision
        let localRevision = self.localRevision
        let status: OnboardingServerStatus
        do {
            status = try await server.fetchStatus(userId: userId)
        } catch {
            Self.logger.notice("onboarding refresh failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Discard an answer that raced a sign-out, a local change, or a queue change (a write
        // accepted mid-fetch may not be in the answer). The next trigger refreshes again.
        guard self.userId == userId,
              outbox.revision == outboxRevision,
              self.localRevision == localRevision,
              let device = progress else { return }

        let merged = OnboardingMerge.merge(
            device: device,
            server: status,
            hasQueuedNameUpdate: outbox.hasPending(OnboardingOutboxKinds.updateProfileName, for: userId),
            now: now()
        )
        apply(merged, for: userId)
        if merged.completed && !status.completed {
            // The device is ahead (e.g. an earlier mark was dropped): tell the server again.
            outbox.enqueue(OnboardingOutboxKinds.markOnboardingCompleted, payload: EmptyPayload(), for: userId)
        }
    }

    // MARK: - Local changes

    /// Profile setup: saves the trimmed names to the device copy and queues the server write.
    func saveProfileName(firstName: String, lastName: String) {
        guard let userId, var updated = progress else { return }
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.firstName = first
        updated.lastName = last
        updated.nextStep = OnboardingProgress.nextStep(firstName: first, lastName: last)
        updated.updatedAt = now()
        localRevision += 1
        apply(updated, for: userId)
        outbox.enqueue(OnboardingOutboxKinds.updateProfileName,
                       payload: ProfileNamePayload(firstName: first, lastName: last), for: userId)
    }

    /// The permissions screen finished. Only with every account step satisfied.
    func markCompleted() {
        guard let userId, var updated = progress, updated.nextStep == nil, !updated.completed else { return }
        updated.completed = true
        updated.updatedAt = now()
        localRevision += 1
        apply(updated, for: userId)
        outbox.enqueue(OnboardingOutboxKinds.markOnboardingCompleted, payload: EmptyPayload(), for: userId)
    }

    // MARK: - Private

    private func reset() {
        userId = nil
        refreshTask = nil
        if progress != nil { progress = nil }
    }

    /// Saves and publishes. A merge with no real change keeps the old copy (and its
    /// `updatedAt`), so a refresh doesn't re-render every observer.
    private func apply(_ new: OnboardingProgress, for userId: UUID) {
        if let current = progress, current.hasSameContent(as: new) { return }
        store.save(new, for: userId)
        progress = new
    }
}

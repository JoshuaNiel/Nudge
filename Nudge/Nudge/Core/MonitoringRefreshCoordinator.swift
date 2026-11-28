import Foundation

/// The one entry point for `NudgeApp`'s monitoring refresh (fetch profile + goals, then
/// re-register, ADR-054/055), which has two triggers:
///
/// - **The foreground sync** (`force: false`): re-registers only when the registration is stale.
/// - **An in-app Screen Time approval** (`force: true`, device finding C): re-registers now,
///   not on the next foreground. Forced because after a revoke the stamps can look fresh.
///
/// **Single flight.** Never two refreshes at once. A forced request during a run cannot join
/// it (that run may already have decided not to register), so it runs once more, forced, right
/// after; several such requests coalesce into one rerun. An unforced request during a run joins
/// it. The returned task finishes when the run and any rerun are done.
///
/// Holds no data itself; the work closure is passed in per call, like `ForegroundSync`.
@MainActor
final class MonitoringRefreshCoordinator {
    typealias Work = @MainActor (_ userId: UUID, _ force: Bool) async -> Void

    private struct Rerun {
        let userId: UUID
    }

    private var inFlight: Task<Void, Never>?
    private var rerun: Rerun?

    var isRunning: Bool { inFlight != nil }

    @discardableResult
    func request(userId: UUID, force: Bool, perform work: @escaping Work) -> Task<Void, Never> {
        if let inFlight {
            if force { rerun = Rerun(userId: userId) }
            return inFlight
        }
        let task = Task { [weak self] in
            await work(userId, force)
            // Reruns requested meanwhile, forced, until none is left.
            while let next = self?.takeRerun() {
                await work(next.userId, true)
            }
            self?.inFlight = nil
        }
        inFlight = task
        return task
    }

    private func takeRerun() -> Rerun? {
        defer { rerun = nil }
        return rerun
    }
}

import SwiftUI

/// Decides when `NudgeApp`'s foreground sync runs, and runs at most one at a time.
///
/// - **Once per foreground** (`ForegroundGate`). Only a return from `.background` re-arms it.
///   Bounces through `.inactive` (system alerts, Face ID, AutoFill, the Screen Time and
///   notification prompts, Control Center) are not a new foreground and do not re-run it.
/// - **Waits for the user.** On a cold start the scene can become active before the
///   Supabase session check publishes the user. The request is then held and runs when
///   `userChanged(to:)` reports a user — once, not on every later user update (token refresh).
/// - **Single flight.** A request while a run is in progress joins that run instead of
///   starting a second one.
///
/// Holds no data itself; the work closure is passed in per call, so `NudgeApp` (a value
/// type) can supply a closure that reads its current state.
@MainActor
final class ForegroundSync {
    typealias Work = @MainActor (UUID) async -> Void

    /// Which `.active` phases start a real foreground (shared with the Dashboard).
    private var gate = ForegroundGate()
    /// A foreground happened before a user was known; run once one is.
    private(set) var isWaitingForUser = false
    private var inFlight: Task<Void, Never>?

    var isRunning: Bool { inFlight != nil }

    /// Wire to `scenePhase` changes. Returns the run started or joined, if any.
    @discardableResult
    func scenePhaseChanged(to phase: ScenePhase, userId: UUID?, perform work: @escaping Work) -> Task<Void, Never>? {
        guard gate.scenePhaseChanged(to: phase) else { return nil }
        return request(userId: userId, work: work)
    }

    /// Wire to changes of the signed-in user's id. Runs only a request that was waiting
    /// for a user. Returns the run started or joined, if any.
    @discardableResult
    func userChanged(to userId: UUID?, perform work: @escaping Work) -> Task<Void, Never>? {
        guard isWaitingForUser, userId != nil else { return nil }
        return request(userId: userId, work: work)
    }

    private func request(userId: UUID?, work: @escaping Work) -> Task<Void, Never>? {
        guard let userId else {
            isWaitingForUser = true
            return nil
        }
        isWaitingForUser = false
        if let inFlight { return inFlight }
        let task = Task { [weak self] in
            await work(userId)
            self?.inFlight = nil
        }
        inFlight = task
        return task
    }
}

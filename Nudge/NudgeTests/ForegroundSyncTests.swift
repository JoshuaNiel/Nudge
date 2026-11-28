import Testing
import Foundation
import SwiftUI
@testable import Nudge

// MARK: - ForegroundSync (NudgeApp's foreground handler gate)
//
// The foreground sync (profile + goal fetch, monitoring refresh, trigger drain) must run
// once per real trip to the foreground, never twice at once, and still run once the user
// arrives when the app foregrounds before the cold-start session check finishes.

/// Records each run. A run can be held open (`holdRuns`) to test overlap.
@MainActor
private final class SyncRecorder {
    private(set) var runs: [UUID] = []
    var holdRuns = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var work: ForegroundSync.Work {
        { [self] userId in
            runs.append(userId)
            if holdRuns {
                await withCheckedContinuation { held.append($0) }
            }
        }
    }

    func releaseAll() {
        let pending = held
        held = []
        pending.forEach { $0.resume() }
    }
}

@Suite("ForegroundSync")
@MainActor
struct ForegroundSyncTests {

    private let user = UUID()

    @Test func activeWithUserRunsOnce() async {
        let recorder = SyncRecorder()
        let sync = ForegroundSync()

        await sync.scenePhaseChanged(to: .active, userId: user, perform: recorder.work)?.value

        #expect(recorder.runs == [user])
    }

    @Test func inactiveActiveTogglesDoNotRerun() async {
        // System alerts, Face ID, AutoFill and the Screen Time / notification prompts
        // bounce the scene through .inactive without leaving the foreground.
        let recorder = SyncRecorder()
        let sync = ForegroundSync()

        await sync.scenePhaseChanged(to: .active, userId: user, perform: recorder.work)?.value
        for _ in 0..<4 {
            await sync.scenePhaseChanged(to: .inactive, userId: user, perform: recorder.work)?.value
            await sync.scenePhaseChanged(to: .active, userId: user, perform: recorder.work)?.value
        }

        #expect(recorder.runs.count == 1)
    }

    @Test func returningFromBackgroundRunsAgain() async {
        let recorder = SyncRecorder()
        let sync = ForegroundSync()

        await sync.scenePhaseChanged(to: .active, userId: user, perform: recorder.work)?.value
        await sync.scenePhaseChanged(to: .inactive, userId: user, perform: recorder.work)?.value
        await sync.scenePhaseChanged(to: .background, userId: user, perform: recorder.work)?.value
        await sync.scenePhaseChanged(to: .inactive, userId: user, perform: recorder.work)?.value
        await sync.scenePhaseChanged(to: .active, userId: user, perform: recorder.work)?.value

        #expect(recorder.runs.count == 2)
    }

    @Test func coldStartWithoutUserWaitsThenRunsWhenUserArrives() async {
        let recorder = SyncRecorder()
        let sync = ForegroundSync()

        let early = sync.scenePhaseChanged(to: .active, userId: nil, perform: recorder.work)
        #expect(early == nil)
        #expect(recorder.runs.isEmpty)
        #expect(sync.isWaitingForUser)

        await sync.userChanged(to: user, perform: recorder.work)?.value

        #expect(recorder.runs == [user])
        #expect(sync.isWaitingForUser == false)
    }

    @Test func userChangeWhileWaitingForNilKeepsWaiting() {
        let recorder = SyncRecorder()
        let sync = ForegroundSync()

        _ = sync.scenePhaseChanged(to: .active, userId: nil, perform: recorder.work)
        #expect(sync.userChanged(to: nil, perform: recorder.work) == nil)

        #expect(sync.isWaitingForUser)
        #expect(recorder.runs.isEmpty)
    }

    @Test func userChangeWhenNotWaitingDoesNotRun() async {
        // The user is already known (e.g. a token refresh re-publishes it): no extra sync.
        let recorder = SyncRecorder()
        let sync = ForegroundSync()

        await sync.scenePhaseChanged(to: .active, userId: user, perform: recorder.work)?.value
        #expect(sync.userChanged(to: user, perform: recorder.work) == nil)
        #expect(sync.userChanged(to: UUID(), perform: recorder.work) == nil)

        #expect(recorder.runs.count == 1)
    }

    @Test func waitingUserThenActiveDoesNotRunTwice() async {
        // Cold start: the user arrives, the deferred sync runs, then the scene settles
        // to .active again. Still one sync for this foreground.
        let recorder = SyncRecorder()
        let sync = ForegroundSync()

        _ = sync.scenePhaseChanged(to: .active, userId: nil, perform: recorder.work)
        await sync.userChanged(to: user, perform: recorder.work)?.value
        await sync.scenePhaseChanged(to: .inactive, userId: user, perform: recorder.work)?.value
        await sync.scenePhaseChanged(to: .active, userId: user, perform: recorder.work)?.value

        #expect(recorder.runs.count == 1)
    }

    @Test func overlappingRequestsJoinTheRunInFlight() async {
        let recorder = SyncRecorder()
        recorder.holdRuns = true
        let sync = ForegroundSync()

        let first = sync.scenePhaseChanged(to: .active, userId: user, perform: recorder.work)
        await Task.yield()
        #expect(sync.isRunning)

        // A full background → foreground trip while the first run is still going.
        _ = sync.scenePhaseChanged(to: .background, userId: user, perform: recorder.work)
        let second = sync.scenePhaseChanged(to: .active, userId: user, perform: recorder.work)
        await Task.yield()

        #expect(recorder.runs.count == 1)

        recorder.releaseAll()
        await first?.value
        await second?.value

        #expect(recorder.runs.count == 1)
        #expect(sync.isRunning == false)
    }

    @Test func nextForegroundAfterRunFinishesRunsAgain() async {
        let recorder = SyncRecorder()
        let sync = ForegroundSync()

        await sync.scenePhaseChanged(to: .active, userId: user, perform: recorder.work)?.value
        #expect(sync.isRunning == false)
        _ = sync.scenePhaseChanged(to: .background, userId: user, perform: recorder.work)
        await sync.scenePhaseChanged(to: .active, userId: user, perform: recorder.work)?.value

        #expect(recorder.runs.count == 2)
    }
}

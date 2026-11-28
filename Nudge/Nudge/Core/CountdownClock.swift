import Foundation
import Combine

/// Time source for on-screen countdowns, injectable so tests can move time without sleeping.
///
/// Countdowns compute what's left from `now` instead of counting ticks, so a countdown
/// stays correct when the app is backgrounded (the timer pauses) and comes back.
protocol CountdownClock {
    var now: Date { get }

    /// Calls `onTick` on the main thread roughly once a second until the token is cancelled.
    func ticks(_ onTick: @escaping () -> Void) -> AnyCancellable
}

/// The real clock: wall time plus a 1-second main-run-loop timer.
struct SystemCountdownClock: CountdownClock {
    var now: Date { Date() }

    func ticks(_ onTick: @escaping () -> Void) -> AnyCancellable {
        // `.common` keeps ticking while the user scrolls.
        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in onTick() }
    }
}

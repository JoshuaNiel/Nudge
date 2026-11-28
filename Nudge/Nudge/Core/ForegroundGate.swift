import SwiftUI

/// The "real foreground" rule, shared by `ForegroundSync` and the Dashboard's automatic
/// refresh (docs/specs/phase-2-dashboard.md D3).
///
/// Only a return from `.background` re-arms it. Bounces through `.inactive` (system alerts,
/// Face ID, the Screen Time and notification prompts, Control Center, notification center)
/// are not a new foreground. It starts armed, so the first `.active` after launch counts.
struct ForegroundGate {
    private var isArmed = true

    /// Feed every `scenePhase` value. True only for the `.active` that starts a real foreground.
    mutating func scenePhaseChanged(to phase: ScenePhase) -> Bool {
        switch phase {
        case .background:
            isArmed = true
            return false
        case .active:
            guard isArmed else { return false }
            isArmed = false
            return true
        default:
            return false
        }
    }
}

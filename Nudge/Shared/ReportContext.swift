import DeviceActivity
import SwiftUI

// The context that pairs the app's `DeviceActivityReport` with the extension's
// report scene. Defined once so the two raw strings cannot drift — a mismatch
// renders a blank report with no error.
//
// Compiled into the `Nudge` app and the `NudgeActivityReport` extension only. It is
// excluded from `NudgeActivityMonitor` (membership exception in project.pbxproj)
// because `DeviceActivityReport` lives in the SwiftUI cross-import overlay, and the
// monitor extension — which runs under a tight memory limit — should not link
// SwiftUI for one constant.
extension DeviceActivityReport.Context {
    static let nudgeSummary = Self("NudgeSummary")
}

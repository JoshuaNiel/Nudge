import DeviceActivity
import ExtensionKit
import SwiftUI

extension DeviceActivityReport.Context {
    static let nudgeSummary = Self("NudgeSummary")
}

// Phase 2 placeholder.
// Configuration type and makeConfiguration body will be replaced with
// DailyUsageSummary + DashboardReportView in Phase 2.
// See specs/phase-2-dashboard.md for the full design.
struct NudgeUsageReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .nudgeSummary
    let content: ([String]) -> NudgeUsageCaptureView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> [String] {
        return []
    }
}

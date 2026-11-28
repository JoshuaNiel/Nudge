import DeviceActivity
import SwiftUI
import ExtensionKit

/// Display-only report extension (ADR-049): it renders usage on-device and never
/// persists or transmits it — the sandbox forbids both.
///
/// `@MainActor` because every `DeviceActivityReportScene` is main-actor isolated
/// (it refines ExtensionKit's `@MainActor AppExtensionScene`) while the SDK leaves
/// `DeviceActivityReportExtension.body` unannotated. Without it, building the scene
/// in `body` warns, and is an error in Swift 6 mode. The system only reads `body`
/// from the main-actor `configuration` requirement, so this matches reality.
@main
@MainActor
struct NudgeActivityReport: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        NudgeUsageReport { report in DashboardReportView(report: report) }
    }
}

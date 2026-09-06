import DeviceActivity
import SwiftUI
import ExtensionKit

@main
struct NudgeActivityReport: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        NudgeUsageReport { _ in NudgeUsageCaptureView() }
    }
}

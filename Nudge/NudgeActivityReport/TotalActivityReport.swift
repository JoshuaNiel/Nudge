import DeviceActivity
import ExtensionKit
import ManagedSettings
import SwiftUI

/// The day's usage as rendered by `DashboardReportView`. The token rides along so
/// each row can show the real app name and icon via `Label(token)`.
typealias ReportUsageSummary = DailyUsageSummary<ApplicationToken>
typealias ReportUsageEntry = AppUsageEntry<ApplicationToken>

/// Adapts `DeviceActivityResults` into the plain samples `DailyUsageSummary`
/// aggregates (see `Shared/UsageSummary.swift`, where the logic is unit tested).
/// This type only walks Apple's async sequences; it holds no business rules.
struct NudgeUsageReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .nudgeSummary
    let content: (ReportUsageSummary) -> DashboardReportView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> ReportUsageSummary {
        var segments: [UsageSegmentSample<ApplicationToken>] = []

        // One `DeviceActivityData` per user/device; each holds one segment per
        // filter interval (a single day for the dashboard's `.daily` filter).
        for await datum in data {
            for await segment in datum.activitySegments {
                var apps: [AppUsageSample<ApplicationToken>] = []
                for await category in segment.categories {
                    for await activity in category.applications {
                        apps.append(
                            AppUsageSample(
                                bundleId: activity.application.bundleIdentifier,
                                localizedName: activity.application.localizedDisplayName,
                                token: activity.application.token,
                                duration: activity.totalActivityDuration,
                                pickups: activity.numberOfPickups
                            )
                        )
                    }
                }
                segments.append(
                    UsageSegmentSample(
                        totalDuration: segment.totalActivityDuration,
                        pickupsWithoutApp: segment.totalPickupsWithoutApplicationActivity,
                        apps: apps
                    )
                )
            }
        }

        return .aggregate(segments)
    }
}

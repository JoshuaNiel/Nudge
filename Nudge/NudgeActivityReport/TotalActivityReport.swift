import DeviceActivity
import ExtensionKit
import ManagedSettings
import SwiftUI

/// The day's or week's usage as rendered by `DashboardReportView`. The tokens ride along so
/// each row can show the real app or category name and icon via `Label(token)`.
typealias ReportUsage = UsageReport<ApplicationToken, ActivityCategoryToken>
typealias ReportUsageSummary = DailyUsageSummary<ApplicationToken>
typealias ReportUsageEntry = AppUsageEntry<ApplicationToken>
typealias ReportCategoryEntry = CategoryUsageEntry<ActivityCategoryToken>

/// Adapts `DeviceActivityResults` into the plain samples `UsageReport` aggregates (see
/// `Shared/UsageReport.swift` and `Shared/UsageSummary.swift`, where the logic is unit tested).
/// This type only walks Apple's async sequences; it holds no business rules.
struct NudgeUsageReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .nudgeSummary
    let content: (ReportUsage) -> DashboardReportView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> ReportUsage {
        var segments: [UsageSegmentSample<ApplicationToken>] = []
        var categories: [CategoryUsageSample<ActivityCategoryToken>] = []
        var interval: DateInterval?

        // One `DeviceActivityData` per user/device; each holds one segment per day of the
        // filter (`.daily`): one for Day mode, one per day of the week for Week mode (V2).
        for await datum in data {
            // The filter's interval is how the report knows Day from Week (`UsageReportScope`).
            interval = interval ?? Self.interval(of: datum.segmentInterval)
            for await segment in datum.activitySegments {
                var apps: [AppUsageSample<ApplicationToken>] = []
                for await category in segment.categories {
                    categories.append(
                        CategoryUsageSample(
                            token: category.category.token,
                            localizedName: category.category.localizedDisplayName,
                            duration: category.totalActivityDuration
                        )
                    )
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

        // The extension's own clock decides how many of the current week's days count (V4).
        return .make(segments: segments, categories: categories, interval: interval,
                     today: Date(), calendar: .current)
    }

    private static func interval(of segmentInterval: DeviceActivityFilter.SegmentInterval) -> DateInterval? {
        switch segmentInterval {
        case .hourly(let interval), .daily(let interval), .weekly(let interval):
            interval
        @unknown default:
            nil
        }
    }
}

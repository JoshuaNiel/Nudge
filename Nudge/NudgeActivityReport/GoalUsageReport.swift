import DeviceActivity
import ExtensionKit
import SwiftUI

/// Phase 3 G8: today's exact usage for one goal. The host app builds the filter from
/// the goal's selection (no tokens = total), so every segment here is already scoped to
/// the goal's apps/categories; this scene only sums them. Rules live in
/// `Shared/GoalUsage.swift`, where they are unit tested.
struct GoalUsageReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .goalUsage
    let content: (GoalUsageSummary) -> GoalUsageReportView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> GoalUsageSummary {
        var durations: [TimeInterval] = []
        for await datum in data {
            for await segment in datum.activitySegments {
                durations.append(segment.totalActivityDuration)
            }
        }
        return .total(ofSegmentDurations: durations)
    }
}

/// Fills the fixed frame the host gives it (ADR-044). The opaque background covers the
/// host's loading indicator once drawn and matches the card it sits in.
struct GoalUsageReportView: View {
    let summary: GoalUsageSummary

    var body: some View {
        VStack(spacing: 4) {
            if summary.totalSeconds > 0 {
                Text(summary.totalSeconds.formattedDuration)
                    .font(.largeTitle.bold())
                    .monospacedDigit()
                Text("used today")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(summary.text)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemGroupedBackground))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.text)
    }
}

import FamilyControls
import ManagedSettings
import SwiftUI

/// The dashboard body, rendered inside the host app's `DeviceActivityReport` frame.
///
/// It scrolls on its own: the host cannot size a remote view to its content, so
/// the host gives it the remaining screen and long app lists scroll here. The
/// opaque background also covers the host's loading `ProgressView` once drawn.
struct DashboardReportView: View {
    let summary: ReportUsageSummary

    var body: some View {
        Group {
            if summary.isEmpty {
                ContentUnavailableView(
                    "No usage recorded for this day",
                    systemImage: "hourglass",
                    description: Text("Screen time shows up here once you use your phone.")
                )
            } else {
                List {
                    Section {
                        header
                    }
                    Section("Apps") {
                        ForEach(summary.apps) { entry in
                            AppUsageRow(
                                entry: entry,
                                fraction: UsageBar.fraction(seconds: entry.seconds, totalSeconds: summary.totalSeconds)
                            )
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Total Screen Time")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary.totalSeconds.formattedDuration)
                    .font(.largeTitle.bold())
                    .monospacedDigit()
                Text("·")
                    .foregroundStyle(.secondary)
                Text(UsageFormatting.pickups(summary.totalPickups))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// One app: name (with icon when a token is available), duration, and a bar
/// proportional to its share of the day.
private struct AppUsageRow: View {
    let entry: ReportUsageEntry
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                name
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(entry.seconds.formattedDuration)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            UsageBarView(fraction: fraction)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var name: some View {
        if let token = entry.token {
            // Apple's supported way to show an app's real name and icon inside a
            // report extension; the token is opaque to us.
            Label(token)
                .labelStyle(.titleAndIcon)
        } else {
            Text(entry.displayName)
        }
    }
}

private struct UsageBarView: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: UsageBar.width(fraction: fraction, availableWidth: proxy.size.width))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

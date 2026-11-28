import FamilyControls
import ManagedSettings
import SwiftUI

/// The dashboard body, rendered inside the host app's `DeviceActivityReport` frame.
///
/// It scrolls on its own: the host cannot size a remote view to its content, so
/// the host gives it the remaining screen and long lists scroll here. The opaque
/// background also covers the host's loading spinner (and Reload fallback) once drawn.
///
/// The Totals | Averages (V4) and Apps | Categories (V5) controls live here, not in the host:
/// the host can only change the filter, and the data needed to switch them is already here.
/// Whether their `@State` survives a filter change (a new configuration) is a device check (V5).
struct DashboardReportView: View {
    let report: ReportUsage

    @State private var measure = UsageMeasure.totals
    @State private var breakdown = UsageBreakdown.apps

    var body: some View {
        Group {
            if report.isEmpty {
                ContentUnavailableView(
                    UsageFormatting.emptyTitle(for: report.scope),
                    systemImage: "hourglass",
                    description: Text("Screen time shows up here once you use your phone.")
                )
            } else {
                list(report.figures(measure))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func list(_ figures: ReportUsage.Figures) -> some View {
        List {
            Section {
                if report.scope.showsMeasurePicker {
                    SegmentedPicker("Measure", selection: $measure) { $0.title }
                }
                header(figures)
            }
            Section {
                rows(figures)
            } header: {
                SegmentedPicker("Breakdown", selection: $breakdown) { $0.title }
                    // A control, not a caption: no uppercasing, and as wide as the rows.
                    .textCase(nil)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }
        }
        .listStyle(.insetGrouped)
    }

    private func header(_ figures: ReportUsage.Figures) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(UsageFormatting.headline(perDay: figures.isPerDay))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(figures.summary.totalSeconds.formattedDuration)
                    .font(.largeTitle.bold())
                    .monospacedDigit()
                Text("·")
                    .foregroundStyle(.secondary)
                Text(UsageFormatting.pickups(figures.summary.totalPickups, perDay: figures.isPerDay))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func rows(_ figures: ReportUsage.Figures) -> some View {
        let total = figures.summary.totalSeconds
        switch breakdown {
        case .apps:
            if figures.summary.apps.isEmpty { EmptyBreakdownRow() }
            ForEach(figures.summary.apps) { entry in
                UsageRow(seconds: entry.seconds, perDay: figures.isPerDay,
                         fraction: UsageBar.fraction(seconds: entry.seconds, totalSeconds: total)) {
                    if let token = entry.token {
                        // Apple's supported way to show an app's real name and icon inside a
                        // report extension; the token is opaque to us.
                        Label(token)
                    } else {
                        Text(entry.displayName)
                    }
                }
            }
        case .categories:
            if figures.categories.isEmpty { EmptyBreakdownRow() }
            ForEach(figures.categories) { entry in
                UsageRow(seconds: entry.seconds, perDay: figures.isPerDay,
                         fraction: UsageBar.fraction(seconds: entry.seconds, totalSeconds: total)) {
                    if let token = entry.token {
                        Label(token)
                    } else {
                        Text(entry.displayName)
                    }
                }
            }
        }
    }
}

/// A segmented control over every case of an enum.
private struct SegmentedPicker<Value: Hashable & CaseIterable>: View where Value.AllCases: RandomAccessCollection {
    let label: String
    @Binding var selection: Value
    let title: (Value) -> String

    init(_ label: String, selection: Binding<Value>, title: @escaping (Value) -> String) {
        self.label = label
        self._selection = selection
        self.title = title
    }

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(Value.allCases, id: \.self) { value in
                Text(title(value)).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// Usage was recorded but none of it is attributed to an app or category.
private struct EmptyBreakdownRow: View {
    var body: some View {
        Text("Nothing to show")
            .foregroundStyle(.secondary)
    }
}

/// One app or category: name (with icon when a token is available), duration, and a bar
/// proportional to its share of the period.
private struct UsageRow<Name: View>: View {
    let seconds: Int
    let perDay: Bool
    let fraction: Double
    @ViewBuilder let name: Name

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                name
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(UsageFormatting.duration(seconds, perDay: perDay))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            UsageBarView(fraction: fraction)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
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

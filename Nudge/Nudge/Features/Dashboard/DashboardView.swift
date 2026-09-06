import SwiftUI

// Phase 2 placeholder.
// Full implementation: DeviceActivityReport embedded view with date navigation.
// See specs/phase-2-dashboard.md for the complete design.
struct DashboardView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Dashboard Coming Soon",
                systemImage: "chart.bar.xaxis",
                description: Text("Usage tracking display will be here in Phase 2.")
            )
            .navigationTitle("Dashboard")
        }
    }
}

#Preview {
    DashboardView()
}

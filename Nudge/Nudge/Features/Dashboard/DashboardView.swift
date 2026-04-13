import SwiftUI
import Charts
import Supabase

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = DashboardViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.error {
                    errorView(message: error)
                } else if viewModel.topApps.isEmpty && viewModel.todayTotalSeconds == 0 {
                    emptyView
                } else {
                    contentView
                }
            }
            .navigationTitle("Today")
            .task {
                guard let userId = appState.currentUser?.id else { return }
                await viewModel.load(userId: userId)
            }
            .refreshable {
                guard let userId = appState.currentUser?.id else { return }
                await viewModel.load(userId: userId)
            }
        }
    }

    // MARK: - Content

    private var contentView: some View {
        ScrollView {
            VStack(spacing: 28) {
                totalCard
                if !viewModel.weeklyUsage.isEmpty {
                    weeklyChart
                }
                if !viewModel.topApps.isEmpty {
                    topAppsList
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    private var totalCard: some View {
        VStack(spacing: 8) {
            Text("Screen Time")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(viewModel.todayTotalSeconds.formattedDuration)
                .font(.system(size: 52, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var weeklyChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This Week")
                .font(.headline)
            Chart(viewModel.weeklyUsage) { day in
                BarMark(
                    x: .value("Day", shortDayLabel(from: day.date)),
                    y: .value("Hours", Double(day.seconds) / 3600)
                )
                .foregroundStyle(Color.accentColor)
                .cornerRadius(4)
            }
            .frame(height: 160)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topAppsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Apps")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(viewModel.topApps) { app in
                    HStack {
                        Text(app.appName)
                            .font(.body)
                        Spacer()
                        Text(app.seconds.formattedDuration)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                    if app.id != viewModel.topApps.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Empty / Error

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No usage data yet")
                .font(.headline)
            Text("Usage will appear here once screen time tracking is set up.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Something went wrong")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func shortDayLabel(from dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return "" }
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppState())
}

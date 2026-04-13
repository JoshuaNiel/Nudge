import Foundation
import Combine

class DashboardViewModel: ObservableObject {
    @Published var todayTotalSeconds: Int = 0
    @Published var topApps: [AppUsageWithName] = []
    @Published var weeklyUsage: [DailyTotal] = []
    @Published var isLoading = false
    @Published var error: String? = nil

    private let usageService = UsageService()

    func load(userId: UUID) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        let timeZone = TimeZone.current
        let today = localDateString(timeZone: timeZone)

        do {
            async let total = usageService.fetchTodayTotal(userId: userId, timeZone: timeZone)
            async let top = usageService.fetchTopApps(userId: userId, date: today, limit: 5)
            async let weekly = usageService.fetchWeeklyUsage(userId: userId, timeZone: timeZone)

            todayTotalSeconds = try await total
            topApps = try await top
            weeklyUsage = try await weekly
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func localDateString(timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        return formatter.string(from: Date())
    }
}

// MARK: - Time formatting

extension Int {
    var formattedDuration: String {
        let hours = self / 3600
        let minutes = (self % 3600) / 60
        if hours > 0 && minutes > 0 { return "\(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "0m"
    }
}

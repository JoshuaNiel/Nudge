import Foundation
import Supabase

class UsageService {

    // MARK: - Today's total screen time

    func fetchTodayTotal(userId: UUID, timeZone: TimeZone) async throws -> Int {
        let today = localDateString(timeZone: timeZone)
        let rows: [AppUsage] = try await supabase
            .from("usage")
            .select()
            .eq("user_id", value: userId)
            .eq("date", value: today)
            .execute()
            .value
        return rows.reduce(0) { $0 + $1.seconds }
    }

    // MARK: - Top apps for a given date

    func fetchTopApps(userId: UUID, date: String, limit: Int) async throws -> [AppUsageWithName] {
        let rows: [AppUsageRow] = try await supabase
            .from("usage")
            .select("id, app_id, date, seconds, pickups, app(name)")
            .eq("user_id", value: userId)
            .eq("date", value: date)
            .order("seconds", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows.map { AppUsageWithName(id: $0.id, appId: $0.appId, appName: $0.app.name, date: $0.date, seconds: $0.seconds, pickups: $0.pickups) }
    }

    // MARK: - Weekly usage (last 7 days)

    func fetchWeeklyUsage(userId: UUID, timeZone: TimeZone) async throws -> [DailyTotal] {
        let today = localDateString(timeZone: timeZone)
        let sevenDaysAgo = localDateString(daysAgo: 6, timeZone: timeZone)

        let rows: [AppUsage] = try await supabase
            .from("usage")
            .select("id, user_id, date, app_id, seconds, pickups")
            .eq("user_id", value: userId)
            .gte("date", value: sevenDaysAgo)
            .lte("date", value: today)
            .execute()
            .value

        // Aggregate seconds by date client-side
        var totals: [String: Int] = [:]
        for row in rows {
            totals[row.date, default: 0] += row.seconds
        }

        // Fill all 7 days, including zeros for days with no usage
        return (0...6).map { daysAgo in
            let date = localDateString(daysAgo: daysAgo, timeZone: timeZone)
            return DailyTotal(date: date, seconds: totals[date] ?? 0)
        }.reversed()
    }

    // MARK: - Helpers

    private func localDateString(daysAgo: Int = 0, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}

// MARK: - Intermediate Decodable for joined query

private struct AppUsageRow: Decodable {
    let id: Int
    let appId: String     // app_id
    let date: String
    let seconds: Int
    let pickups: Int
    let app: AppNameOnly

    struct AppNameOnly: Decodable {
        let name: String
    }
}

import Foundation

struct AppUsage: Codable, Identifiable {
    let id: Int
    let userId: UUID       // user_id
    let date: String       // "YYYY-MM-DD" local date in user's timezone
    let appId: String      // app_id (FK → app.bundle_id)
    let seconds: Int
    let pickups: Int
}

struct AppRecord: Codable, Identifiable {
    let bundleId: String   // PK
    let name: String
    var id: String { bundleId }
}

struct AppUsageWithName: Codable, Identifiable {
    let id: Int
    let appId: String      // app_id
    let appName: String    // joined from app.name
    let date: String
    let seconds: Int
    let pickups: Int
}

struct DailyTotal: Identifiable {
    let date: String       // "YYYY-MM-DD"
    let seconds: Int
    var id: String { date }
}

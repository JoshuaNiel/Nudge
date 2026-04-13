import Foundation

struct AppUsage: Codable, Identifiable {
    let id: Int
    let userId: UUID
    let date: String       // "YYYY-MM-DD" local date in user's timezone
    let appId: String      // FK → app.bundle_id
    let seconds: Int
    let pickups: Int

    enum CodingKeys: String, CodingKey {
        case id
        case userId   = "user_id"
        case date
        case appId    = "app_id"
        case seconds
        case pickups
    }
}

struct AppRecord: Codable, Identifiable {
    let bundleId: String   // PK
    let name: String
    var id: String { bundleId }

    enum CodingKeys: String, CodingKey {
        case bundleId = "bundle_id"
        case name
    }
}

struct AppUsageWithName: Codable, Identifiable {
    let id: Int
    let appId: String      // app_id
    let appName: String    // joined from app.name
    let date: String
    let seconds: Int
    let pickups: Int

    enum CodingKeys: String, CodingKey {
        case id
        case appId   = "app_id"
        case appName = "app_name"
        case date
        case seconds
        case pickups
    }
}

struct DailyTotal: Identifiable {
    let date: String       // "YYYY-MM-DD"
    let seconds: Int
    var id: String { date }
}

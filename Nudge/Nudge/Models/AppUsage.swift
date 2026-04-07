import Foundation

struct AppUsage: Identifiable, Codable {
    let id: UUID
    let bundleID: String
    let appName: String
    let category: String?
    let durationSeconds: Int
    let date: Date

    init(id: UUID = UUID(), bundleID: String, appName: String, category: String? = nil, durationSeconds: Int, date: Date = .now) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.category = category
        self.durationSeconds = durationSeconds
        self.date = date
    }
}

import Foundation

struct Goal: Identifiable, Codable {
    let id: UUID
    var title: String
    var reason: String         // "why" reminder shown in notifications
    var dailyLimitMinutes: Int
    var appBundleIDs: [String] // which apps this goal applies to
    var createdAt: Date

    init(id: UUID = UUID(), title: String, reason: String, dailyLimitMinutes: Int, appBundleIDs: [String] = [], createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.reason = reason
        self.dailyLimitMinutes = dailyLimitMinutes
        self.appBundleIDs = appBundleIDs
        self.createdAt = createdAt
    }
}

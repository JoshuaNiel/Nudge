import Foundation

// MARK: - WhyReminder

/// A personal reason attached to a goal (Phase 4). When the goal reaches
/// `notifyPercent` of its limit, the monitor extension shows `message` in a notification.
struct WhyReminder: Codable, Identifiable, Equatable {
    let id: Int
    let userId: UUID
    let goalId: Int
    let message: String
    /// 10…100 in steps of 10 (DB check `why_reminder_percent_step`).
    let notifyPercent: Int

    enum CodingKeys: String, CodingKey {
        case id
        case userId        = "user_id"
        case goalId        = "goal_id"
        case message
        case notifyPercent = "notify_percent"
    }
}

// MARK: - Write models

struct WhyReminderInsert: Encodable {
    let userId: UUID
    let goalId: Int
    let message: String
    let notifyPercent: Int

    enum CodingKeys: String, CodingKey {
        case userId        = "user_id"
        case goalId        = "goal_id"
        case message
        case notifyPercent = "notify_percent"
    }
}

/// Edit payload. The owner and the goal are never rewritten (migration 007 grants UPDATE
/// on only these two columns).
struct WhyReminderUpdate: Encodable {
    let message: String
    let notifyPercent: Int

    enum CodingKeys: String, CodingKey {
        case message
        case notifyPercent = "notify_percent"
    }
}

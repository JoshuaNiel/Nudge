import Foundation

/// Pure why-reminder rules (Phase 4), unit-tested in NudgeTests/WhyReminderTests.swift.
/// The database enforces the same rules (`varchar(500)`, `why_reminder_message_not_blank`,
/// `why_reminder_percent_step`).
enum WhyReminderRules {

    /// `why_reminder.message` is `varchar(500)`.
    static let messageMaxLength = 500

    /// Every milestone percent (10…100 step 10), so every why lines up with a registered
    /// event and no extra events are needed.
    static var allowedPercents: [Int] { MonitoringPlan.milestonePercents }

    static let defaultPercent = 80

    static func normalizedMessage(_ message: String) -> String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Length as Postgres counts it: `varchar(n)` limits code points, not the grapheme
    /// clusters `String.count` returns (an emoji family is 1 Character, 7 code points).
    static func length(of message: String) -> Int {
        message.unicodeScalars.count
    }

    static func messageError(_ message: String) -> String? {
        let trimmed = normalizedMessage(message)
        if trimmed.isEmpty { return "Write a reason." }
        if length(of: trimmed) > messageMaxLength { return "Keep it to \(messageMaxLength) characters or fewer." }
        return nil
    }

    static func isValidPercent(_ percent: Int) -> Bool {
        allowedPercents.contains(percent)
    }

    static func percentError(_ percent: Int) -> String? {
        isValidPercent(percent) ? nil : "Choose a percentage between 10% and 100%."
    }

    static func validationError(message: String, percent: Int) -> String? {
        messageError(message) ?? percentError(percent)
    }

    /// "at 80%"
    static func percentCaption(_ percent: Int) -> String {
        "at \(percent)%"
    }
}

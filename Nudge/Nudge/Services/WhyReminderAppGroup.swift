import Foundation
import os

// MARK: - Payload builder

extension WhyReminderPayload {

    /// Groups reminders by goal and percent. Messages are ordered by id so the extension's
    /// round-robin order is stable whatever order Supabase returns rows in.
    static func byGoal(from reminders: [WhyReminder]) -> WhyRemindersByGoal {
        var result: WhyRemindersByGoal = [:]
        for reminder in reminders.sorted(by: { $0.id < $1.id }) {
            result[reminder.goalId, default: [:]][reminder.notifyPercent, default: []].append(reminder.message)
        }
        return result
    }
}

// MARK: - Writer

/// Writes the user's complete reminder list to the App Group for the monitor extension.
/// A protocol so ViewModels are tested without the App Group.
protocol WhyReminderAppGroupWriting {
    /// `reminders` must be the user's *complete* list: it replaces the stored copy.
    func write(_ reminders: [WhyReminder])
}

struct AppGroupWhyReminderWriter: WhyReminderAppGroupWriting {
    private let defaults: UserDefaults?

    init() { self.defaults = UserDefaults(suiteName: AppGroupKeys.suiteName) }
    init(defaults: UserDefaults) { self.defaults = defaults }

    func write(_ reminders: [WhyReminder]) {
        guard let defaults else { return }
        WhyReminderStore(defaults: defaults).write(WhyReminderPayload.byGoal(from: reminders))
    }
}

// MARK: - Foreground sync

/// Refreshes the App Group copy from Supabase on every foreground.
///
/// Only a successful fetch is written. A failed request must not look like "no whys"
/// (the ADR-055 failure class): yesterday's copy is strictly better than an empty one.
@MainActor
final class WhyReminderSync {
    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "WhyReminderSync")

    private let service: ReminderServiceProtocol
    private let writer: WhyReminderAppGroupWriting

    // Production init (ADR-028 two-init pattern).
    init() {
        self.service = ReminderService()
        self.writer = AppGroupWhyReminderWriter()
    }

    // Test init.
    init(service: ReminderServiceProtocol, writer: WhyReminderAppGroupWriting) {
        self.service = service
        self.writer = writer
    }

    /// Returns whether the App Group copy was refreshed.
    @discardableResult
    func refresh(userId: UUID) async -> Bool {
        do {
            let reminders = try await service.fetchReminders(userId: userId)
            writer.write(reminders)
            return true
        } catch {
            Self.logger.error("reminder fetch failed — keeping the existing App Group copy: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

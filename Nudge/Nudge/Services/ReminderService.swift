import Foundation
import Supabase

// MARK: - Protocol

/// CRUD for `why_reminder` (Phase 4). Input is validated by the caller
/// (`WhyReminderRules`); the database enforces the same rules again.
protocol ReminderServiceProtocol {
    /// Every reminder the user has, across all goals.
    func fetchReminders(userId: UUID) async throws -> [WhyReminder]
    func addReminder(userId: UUID, goalId: Int, message: String, notifyPercent: Int) async throws -> WhyReminder
    func updateReminder(id: Int, userId: UUID, message: String, notifyPercent: Int) async throws -> WhyReminder
    func deleteReminder(id: Int, userId: UUID) async throws
}

// MARK: - Service

/// Every query is scoped to `user_id` in addition to RLS (defense in depth). RLS also
/// checks that a reminder's goal belongs to the user (migration 007).
@MainActor
final class ReminderService: ReminderServiceProtocol {

    func fetchReminders(userId: UUID) async throws -> [WhyReminder] {
        try await supabase
            .from("why_reminder")
            .select()
            .eq("user_id", value: userId)
            .execute()
            .value
    }

    func addReminder(userId: UUID, goalId: Int, message: String, notifyPercent: Int) async throws -> WhyReminder {
        try await supabase
            .from("why_reminder")
            .insert(WhyReminderInsert(userId: userId, goalId: goalId, message: message, notifyPercent: notifyPercent))
            .select()
            .single()
            .execute()
            .value
    }

    func updateReminder(id: Int, userId: UUID, message: String, notifyPercent: Int) async throws -> WhyReminder {
        try await supabase
            .from("why_reminder")
            .update(WhyReminderUpdate(message: message, notifyPercent: notifyPercent))
            .eq("id", value: id)
            .eq("user_id", value: userId)
            .select()
            .single()
            .execute()
            .value
    }

    func deleteReminder(id: Int, userId: UUID) async throws {
        try await supabase
            .from("why_reminder")
            .delete()
            .eq("id", value: id)
            .eq("user_id", value: userId)
            .execute()
    }
}

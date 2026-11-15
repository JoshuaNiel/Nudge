import Foundation
import Combine

/// The "Why" section of one goal's detail screen (Phase 4).
///
/// Loads *all* of the user's reminders (one request) and shows this goal's. The full list
/// is kept because every successful write replaces the App Group copy, which covers every
/// goal — so writes are refused until a load has succeeded, otherwise one goal's edit
/// would wipe every other goal's whys from the extension's copy.
@MainActor
final class WhyRemindersViewModel: ObservableObject {
    /// This goal's whys, by percent then creation order.
    @Published private(set) var reminders: [WhyReminder] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published var loadError: String? = nil
    /// Delete failure, shown inline in the section.
    @Published var actionError: String? = nil

    let goalId: Int

    private var allReminders: [WhyReminder] = [] {
        didSet { reminders = Self.visible(allReminders, goalId: goalId) }
    }

    private let service: ReminderServiceProtocol
    private let writer: WhyReminderAppGroupWriting

    static let notLoadedMessage = "Your whys haven't loaded yet. Try again in a moment."
    static let genericSaveMessage = "Couldn't save your why. Please try again."

    // Production init (ADR-028 two-init pattern).
    init(goalId: Int) {
        self.goalId = goalId
        self.service = ReminderService()
        self.writer = AppGroupWhyReminderWriter()
    }

    // Test init.
    init(goalId: Int, service: ReminderServiceProtocol, writer: WhyReminderAppGroupWriting) {
        self.goalId = goalId
        self.service = service
        self.writer = writer
    }

    // MARK: - Loading

    func load(userId: UUID) async {
        loadError = nil
        isLoading = true
        defer { isLoading = false }
        do {
            allReminders = try await service.fetchReminders(userId: userId)
            hasLoaded = true
            // A fresh, complete fetch: as good a time as any to refresh the extension's copy.
            writer.write(allReminders)
        } catch {
            loadError = "Couldn't load your whys."
        }
    }

    // MARK: - Writes

    /// Returns a user-facing error, or `nil` when saved.
    func add(userId: UUID, message: String, percent: Int) async -> String? {
        guard hasLoaded else { return Self.notLoadedMessage }
        if let error = WhyReminderRules.validationError(message: message, percent: percent) { return error }

        do {
            let saved = try await service.addReminder(
                userId: userId,
                goalId: goalId,
                message: WhyReminderRules.normalizedMessage(message),
                notifyPercent: percent
            )
            allReminders.append(saved)
        } catch {
            return Self.genericSaveMessage
        }
        writer.write(allReminders)
        return nil
    }

    /// Returns a user-facing error, or `nil` when saved.
    func update(_ reminder: WhyReminder, userId: UUID, message: String, percent: Int) async -> String? {
        guard hasLoaded else { return Self.notLoadedMessage }
        if let error = WhyReminderRules.validationError(message: message, percent: percent) { return error }

        do {
            let saved = try await service.updateReminder(
                id: reminder.id,
                userId: userId,
                message: WhyReminderRules.normalizedMessage(message),
                notifyPercent: percent
            )
            if let index = allReminders.firstIndex(where: { $0.id == saved.id }) {
                allReminders[index] = saved
            } else {
                allReminders.append(saved)
            }
        } catch {
            return Self.genericSaveMessage
        }
        writer.write(allReminders)
        return nil
    }

    @discardableResult
    func delete(_ reminder: WhyReminder, userId: UUID) async -> Bool {
        actionError = nil
        guard hasLoaded else {
            actionError = Self.notLoadedMessage
            return false
        }
        do {
            try await service.deleteReminder(id: reminder.id, userId: userId)
        } catch {
            actionError = "Couldn't delete your why. Please try again."
            return false
        }
        allReminders.removeAll { $0.id == reminder.id }
        writer.write(allReminders)
        return true
    }

    // MARK: - Private

    private static func visible(_ all: [WhyReminder], goalId: Int) -> [WhyReminder] {
        all.filter { $0.goalId == goalId }
            .sorted { ($0.notifyPercent, $0.id) < ($1.notifyPercent, $1.id) }
    }
}

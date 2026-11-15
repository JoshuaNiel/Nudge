import Foundation
import Combine
import Supabase

@MainActor
class SettingsViewModel: ObservableObject {
    @Published var firstName: String = ""
    @Published var lastName: String = ""
    @Published var phoneNumber: String = ""
    @Published var email: String = ""

    @Published var isLoading: Bool = false
    @Published var isSaving: Bool = false
    @Published var errorMessage: String? = nil
    @Published var didSave: Bool = false

    // MARK: Nudge settings (Phase 5E)

    /// The editable copy bound to the "Nudges" section.
    @Published var nudgeSettings: NudgeSettings = .defaults
    /// False until `nudge_settings` loads. While false the Nudges controls are disabled and
    /// never count as changes — the placeholder defaults must not be saved over a row we
    /// failed to read.
    @Published private(set) var nudgeSettingsLoaded: Bool = false
    /// Accepted friends, or nil when unknown (not loaded, or the fetch failed).
    @Published private(set) var acceptedFriendCount: Int? = nil

    private let profileService: ProfileServiceProtocol
    private let nudgeSettingsService: NudgeSettingsServiceProtocol
    private let friendService: FriendServiceProtocol
    private let monitoringService: MonitoringRegistrationServiceProtocol
    private let defaults: UserDefaults?

    // Captured originals from the last load/save, used for dirty-state tracking.
    private var originalFirstName: String = ""
    private var originalLastName: String = ""
    private var originalPhoneNumber: String = ""
    private var originalNudgeSettings: NudgeSettings = .defaults

    // Production init — uses real services (ADR-028 two-init pattern).
    init() {
        self.profileService = ProfileService()
        self.nudgeSettingsService = NudgeSettingsService()
        self.friendService = FriendService()
        self.monitoringService = MonitoringRegistrationService.shared
        self.defaults = UserDefaults(suiteName: AppGroupKeys.suiteName)
    }

    // Test init — accepts mocks and a throwaway `UserDefaults` for the App Group.
    init(
        profileService: ProfileServiceProtocol,
        nudgeSettingsService: NudgeSettingsServiceProtocol,
        friendService: FriendServiceProtocol,
        monitoringService: MonitoringRegistrationServiceProtocol,
        defaults: UserDefaults?
    ) {
        self.profileService = profileService
        self.nudgeSettingsService = nudgeSettingsService
        self.friendService = friendService
        self.monitoringService = monitoringService
        self.defaults = defaults
    }

    // MARK: - Computed

    /// A phone number is acceptable when it is blank (opted out) or valid E.164.
    var isPhoneValid: Bool {
        let trimmed = phoneNumber.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.isValidE164
    }

    var firstNameError: String? {
        firstName.trimmingCharacters(in: .whitespaces).isEmpty ? "First name is required." : nil
    }

    var lastNameError: String? {
        lastName.trimmingCharacters(in: .whitespaces).isEmpty ? "Last name is required." : nil
    }

    var phoneError: String? {
        phoneNumber.e164ValidationError
    }

    /// True if any profile field's trimmed value differs from the captured (trimmed) original.
    var profileHasChanges: Bool {
        firstName.trimmingCharacters(in: .whitespaces) != originalFirstName.trimmingCharacters(in: .whitespaces)
            || lastName.trimmingCharacters(in: .whitespaces) != originalLastName.trimmingCharacters(in: .whitespaces)
            || phoneNumber.trimmingCharacters(in: .whitespaces) != originalPhoneNumber.trimmingCharacters(in: .whitespaces)
    }

    /// Only ever true once the settings actually loaded.
    var nudgeSettingsHaveChanges: Bool {
        nudgeSettingsLoaded && nudgeSettings != originalNudgeSettings
    }

    var hasChanges: Bool { profileHasChanges || nudgeSettingsHaveChanges }

    /// Profile field errors only block saving when the profile is part of the save, so an
    /// untouched (e.g. failed-to-load) profile never blocks a nudge-settings change.
    var canSave: Bool {
        guard hasChanges, !isSaving else { return false }
        return !profileHasChanges || profileFieldError == nil
    }

    private var profileFieldError: String? { firstNameError ?? lastNameError ?? phoneError }

    /// "Add a friend to start sending nudges." — only when we know there are none.
    var showsNoFriendsNote: Bool { acceptedFriendCount == 0 }

    /// `DatePicker` binding for the daily report time. Only hour and minute are kept.
    var dailyReportDate: Date {
        get { nudgeSettings.dailyReportTime.date(on: Date(), calendar: .current) }
        set { nudgeSettings.dailyReportTime = TimeOfDay(date: newValue, calendar: .current) }
    }

    // MARK: - Actions

    /// Loads the profile, nudge settings and friends. Each part fails independently: a
    /// failed profile keeps the existing behaviour, failed settings leave the Nudges
    /// controls disabled, and failed friends just hide the no-friends note.
    func load(userId: UUID, email: String) async {
        self.email = email
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        var failures: [String] = []

        do {
            let profile = try await profileService.fetchProfile(userId: userId)
            firstName = profile.firstName ?? ""
            lastName = profile.lastName ?? ""
            phoneNumber = profile.phoneNumber ?? ""
            captureOriginals()
        } catch {
            failures.append("Couldn't load your profile. Please try again.")
        }

        do {
            let settings = try await nudgeSettingsService.fetch(userId: userId)
            nudgeSettings = settings
            originalNudgeSettings = settings
            nudgeSettingsLoaded = true
            NudgeTriggerSettings.persist(settings.triggerSettings, defaults: defaults)
        } catch {
            nudgeSettingsLoaded = false
            failures.append("Couldn't load your nudge settings. Please try again.")
        }

        if let friends = try? await friendService.fetchFriends(userId: userId) {
            acceptedFriendCount = friends.filter { $0.status == .accepted }.count
        } else {
            acceptedFriendCount = nil
        }

        if !failures.isEmpty {
            errorMessage = failures.joined(separator: " ")
        }
    }

    /// Saves whatever changed. Profile and nudge settings are written independently, so
    /// one failing does not discard the other.
    ///
    /// After a successful settings save: the App Group mirror is updated (goal-breach
    /// toggle takes effect in the extension immediately) and `goalDidChange()` re-arms
    /// monitoring, which picks up a session-timeout change. A failed settings save changes
    /// nothing locally — the edit stays on screen, dirty, for a retry.
    func save(userId: UUID) async {
        let saveProfile = profileHasChanges
        let saveSettings = nudgeSettingsHaveChanges
        guard saveProfile || saveSettings else { return }

        // Defensive: the Save button is disabled while a profile being saved is invalid.
        if saveProfile, let fieldError = profileFieldError {
            errorMessage = fieldError
            return
        }

        didSave = false
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }

        var failures: [String] = []

        if saveProfile {
            do {
                try await saveProfileFields(userId: userId)
            } catch {
                failures.append(Self.userFacingMessage(for: error))
            }
        }

        if saveSettings {
            let settingsToSave = nudgeSettings
            do {
                try await nudgeSettingsService.save(settingsToSave, userId: userId)
                originalNudgeSettings = settingsToSave
                NudgeTriggerSettings.persist(settingsToSave.triggerSettings, defaults: defaults)
                monitoringService.goalDidChange()
            } catch {
                failures.append("Couldn't save your nudge settings. Please try again.")
            }
        }

        guard failures.isEmpty else {
            errorMessage = failures.joined(separator: " ")
            return
        }

        didSave = true
        // Auto-fade the confirmation after a short delay.
        Task {
            try? await Task.sleep(for: .seconds(2))
            didSave = false
        }
    }

    private func saveProfileFields(userId: UUID) async throws {
        let trimmedFirstName = firstName.trimmingCharacters(in: .whitespaces)
        let trimmedLastName = lastName.trimmingCharacters(in: .whitespaces)
        let trimmedPhone = phoneNumber.trimmingCharacters(in: .whitespaces)
        let phoneToSave = trimmedPhone.isEmpty ? nil : trimmedPhone

        try await profileService.updateProfile(
            userId: userId,
            firstName: trimmedFirstName,
            lastName: trimmedLastName,
            phoneNumber: phoneToSave
        )
        // Reflect the just-saved values so `profileHasChanges` becomes false.
        originalFirstName = trimmedFirstName
        originalLastName = trimmedLastName
        originalPhoneNumber = trimmedPhone
    }

    private func captureOriginals() {
        originalFirstName = firstName
        originalLastName = lastName
        originalPhoneNumber = phoneNumber
    }

    // MARK: - Error mapping

    private static func userFacingMessage(for error: Error) -> String {
        // Postgres unique-violation on profile.phone_number (SQLSTATE 23505).
        if let pgError = error as? PostgrestError,
           pgError.code == "23505" || (pgError.message.contains("phone_number") && pgError.message.lowercased().contains("duplicate")) {
            return "That phone number is already in use by another account."
        }
        return "Couldn't save your profile. Please try again."
    }
}

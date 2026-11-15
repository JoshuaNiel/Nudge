import Testing
import Foundation
@testable import Nudge

// Phase 5E-1 — nudge trigger settings (docs/specs/phase-5e-trigger-settings.md).

// MARK: - Helpers

private let userId = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

private struct TestFailure: Error {}

/// A throwaway App Group stand-in, so tests never touch the real shared container.
private func makeDefaults() -> UserDefaults {
    let name = "test.nudgeSettings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
private func decodeSettings(_ json: String) throws -> NudgeSettings {
    try JSONDecoder().decode(NudgeSettings.self, from: Data(json.utf8))
}

private func settingsJSON(time: String, enabled: Bool = true, minutes: Int = 30) -> String {
    """
    {
        "session_timeout_enabled": \(enabled),
        "session_timeout_minutes": \(minutes),
        "goal_breach_enabled": true,
        "daily_report_enabled": true,
        "daily_report_time": "\(time)"
    }
    """
}

private func utcCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

// MARK: - TimeOfDay

@Suite("TimeOfDay")
@MainActor
struct TimeOfDayTests {

    @Test func parsesHoursAndMinutes() {
        #expect(TimeOfDay(string: "08:00") == TimeOfDay(hour: 8, minute: 0))
        #expect(TimeOfDay(string: "21:45") == TimeOfDay(hour: 21, minute: 45))
    }

    @Test func parsesPostgresTimeWithSeconds() {
        #expect(TimeOfDay(string: "08:00:00") == TimeOfDay(hour: 8, minute: 0))
        #expect(TimeOfDay(string: "07:05:59") == TimeOfDay(hour: 7, minute: 5))
    }

    @Test func parsesFractionalSeconds() {
        #expect(TimeOfDay(string: "23:59:59.999999") == TimeOfDay(hour: 23, minute: 59))
    }

    @Test func rejectsMalformedValues() {
        #expect(TimeOfDay(string: "") == nil)
        #expect(TimeOfDay(string: "8") == nil)
        #expect(TimeOfDay(string: "24:00") == nil)
        #expect(TimeOfDay(string: "12:60") == nil)
        #expect(TimeOfDay(string: "-1:00") == nil)
        #expect(TimeOfDay(string: "ab:cd") == nil)
        #expect(TimeOfDay(string: "12:00:61") == nil)
        #expect(TimeOfDay(string: "12:00:00:00") == nil)
    }

    @Test func postgresStringIsZeroPadded() {
        #expect(TimeOfDay(hour: 8, minute: 5).postgresString == "08:05:00")
        #expect(TimeOfDay(hour: 23, minute: 59).postgresString == "23:59:00")
    }

    @Test func codableIsASingleString() throws {
        let data = try JSONEncoder().encode([TimeOfDay(hour: 9, minute: 30)])
        #expect(String(data: data, encoding: .utf8) == #"["09:30:00"]"#)
        let decoded = try JSONDecoder().decode([TimeOfDay].self, from: Data(#"["18:15"]"#.utf8))
        #expect(decoded == [TimeOfDay(hour: 18, minute: 15)])
    }

    @Test func decodingInvalidStringThrows() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([TimeOfDay].self, from: Data(#"["99:99"]"#.utf8))
        }
    }

    @Test func dateRoundTrip() {
        let cal = utcCalendar()
        let day = cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 3))!
        let time = TimeOfDay(hour: 20, minute: 10)

        let date = time.date(on: day, calendar: cal)
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(c.year == 2026 && c.month == 11 && c.day == 14)
        #expect(c.hour == 20 && c.minute == 10 && c.second == 0)
        #expect(TimeOfDay(date: date, calendar: cal) == time)
    }
}

// MARK: - NudgeSettings model

@Suite("NudgeSettings coding")
@MainActor
struct NudgeSettingsCodingTests {

    @Test func defaultsMatchTheSQLDefaults() {
        let d = NudgeSettings.defaults
        #expect(d.sessionTimeoutEnabled == true)
        #expect(d.sessionTimeoutMinutes == 60)
        #expect(d.goalBreachEnabled == false)
        #expect(d.dailyReportEnabled == false)
        #expect(d.dailyReportTime == TimeOfDay(hour: 8, minute: 0))
    }

    @Test func allowedSessionTimeoutsMatchTheSQLCheck() {
        #expect(NudgeSettings.allowedSessionTimeoutMinutes == [15, 30, 60, 90, 120])
        #expect(NudgeSettings.allowedSessionTimeoutMinutes.contains(NudgeSettings.defaults.sessionTimeoutMinutes))
    }

    @Test func decodesPostgresRow() throws {
        let s = try decodeSettings(settingsJSON(time: "21:30:00", enabled: false, minutes: 90))
        #expect(s.sessionTimeoutEnabled == false)
        #expect(s.sessionTimeoutMinutes == 90)
        #expect(s.goalBreachEnabled == true)
        #expect(s.dailyReportEnabled == true)
        #expect(s.dailyReportTime == TimeOfDay(hour: 21, minute: 30))
    }

    @Test func decodesShortTimeFormat() throws {
        let s = try decodeSettings(settingsJSON(time: "06:15"))
        #expect(s.dailyReportTime == TimeOfDay(hour: 6, minute: 15))
    }

    @Test func malformedTimeFailsDecoding() {
        #expect(throws: DecodingError.self) {
            try decodeSettings(settingsJSON(time: "noon"))
        }
    }

    @Test func encodesSnakeCaseKeysAndPostgresTime() throws {
        var s = NudgeSettings.defaults
        s.dailyReportTime = TimeOfDay(hour: 7, minute: 45)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]

        #expect(Set(object.keys) == [
            "session_timeout_enabled", "session_timeout_minutes", "goal_breach_enabled",
            "daily_report_enabled", "daily_report_time",
        ])
        #expect(object["daily_report_time"] as? String == "07:45:00")
    }

    @Test func roundTrips() throws {
        let s = NudgeSettings(
            sessionTimeoutEnabled: false, sessionTimeoutMinutes: 15,
            goalBreachEnabled: true, dailyReportEnabled: true,
            dailyReportTime: TimeOfDay(hour: 22, minute: 5)
        )
        let decoded = try JSONDecoder().decode(NudgeSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded == s)
    }

    @Test func upsertPayloadCarriesUserIdAndNoTimestamp() throws {
        let payload = NudgeSettingsUpsert(userId: userId, settings: .defaults)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]

        #expect(object["user_id"] as? String == userId.uuidString)
        #expect(object["session_timeout_minutes"] as? Int == 60)
        #expect(object["daily_report_time"] as? String == "08:00:00")
        // updated_at is maintained by a DB trigger, never by the client clock.
        #expect(object["updated_at"] == nil)
        #expect(object.keys.contains("userId") == false)
    }

    @Test func noRowMeansDefaults() throws {
        #expect(NudgeSettings.resolve(rows: []) == .defaults)
        let row = try decodeSettings(settingsJSON(time: "10:00:00"))
        #expect(NudgeSettings.resolve(rows: [row]) == row)
    }

    @Test func effectiveSessionTimeoutIsNilWhenDisabled() {
        var s = NudgeSettings.defaults
        #expect(s.effectiveSessionTimeoutMinutes == 60)
        s.sessionTimeoutMinutes = 15
        #expect(s.effectiveSessionTimeoutMinutes == 15)
        s.sessionTimeoutEnabled = false
        #expect(s.effectiveSessionTimeoutMinutes == nil)
    }

    @Test func triggerSettingsMirrorTheModel() {
        var s = NudgeSettings.defaults
        s.goalBreachEnabled = true
        s.dailyReportEnabled = true
        s.dailyReportTime = TimeOfDay(hour: 9, minute: 0)
        #expect(s.triggerSettings == NudgeTriggerSettings(
            goalBreachEnabled: true, dailyReportEnabled: true, dailyReportTime: TimeOfDay(hour: 9, minute: 0)
        ))
    }
}

// MARK: - App Group trigger settings

@Suite("NudgeTriggerSettings App Group")
@MainActor
struct NudgeTriggerSettingsStoreTests {

    @Test func keyName() {
        #expect(AppGroupKeys.nudgeSettings == "nudge.settings")
    }

    @Test func persistAndLoadRoundTrip() {
        let defaults = makeDefaults()
        let settings = NudgeTriggerSettings(
            goalBreachEnabled: true, dailyReportEnabled: true, dailyReportTime: TimeOfDay(hour: 19, minute: 30)
        )
        NudgeTriggerSettings.persist(settings, defaults: defaults)
        #expect(NudgeTriggerSettings.load(from: defaults) == settings)
    }

    @Test func storedJSONUsesSnakeCaseKeys() throws {
        let defaults = makeDefaults()
        NudgeTriggerSettings.persist(.failClosed, defaults: defaults)
        let data = try #require(defaults.data(forKey: AppGroupKeys.nudgeSettings))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(Set(object.keys) == ["goal_breach_enabled", "daily_report_enabled", "daily_report_time"])
    }

    /// The extension fails closed: no stored settings must never text friends.
    @Test func missingSettingsFailClosed() {
        let loaded = NudgeTriggerSettings.load(from: makeDefaults())
        #expect(loaded.goalBreachEnabled == false)
        #expect(loaded.dailyReportEnabled == false)
        #expect(loaded == .failClosed)
    }

    @Test func undecodableSettingsFailClosed() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: AppGroupKeys.nudgeSettings)
        #expect(NudgeTriggerSettings.load(from: defaults).goalBreachEnabled == false)
    }

    @Test func nilDefaultsFailClosed() {
        #expect(NudgeTriggerSettings.load(from: nil) == .failClosed)
    }

    @Test func failClosedMatchesDBDefaults() {
        #expect(NudgeTriggerSettings.failClosed == NudgeSettings.defaults.triggerSettings)
    }
}

// MARK: - Monitoring inputs loader

@MainActor
private final class MockGoalService: GoalServiceProtocol {
    var summaries: [GoalSummary] = []
    var error: Error?

    func fetchGoals(userId: UUID) async throws -> [Goal] { [] }
    func createGoal(_ goal: GoalInsert) async throws {}
    func deleteGoal(id: Int, userId: UUID) async throws {}
    func updateGoalSelection(id: Int, userId: UUID, selection: String) async throws {}
    func fetchGoalSummaries(userId: UUID) async throws -> [GoalSummary] {
        if let error { throw error }
        return summaries
    }
}

@MainActor
private final class MockNudgeSettingsService: NudgeSettingsServiceProtocol {
    var settingsToReturn: NudgeSettings = .defaults
    var fetchError: Error?
    var saveError: Error?
    var fetchCalls = 0
    var saved: [NudgeSettings] = []
    var savedUserIds: [UUID] = []

    func fetch(userId: UUID) async throws -> NudgeSettings {
        fetchCalls += 1
        if let fetchError { throw fetchError }
        return settingsToReturn
    }

    func save(_ settings: NudgeSettings, userId: UUID) async throws {
        if let saveError { throw saveError }
        saved.append(settings)
        savedUserIds.append(userId)
    }
}

@Suite("SupabaseMonitoringInputsLoader")
@MainActor
struct MonitoringInputsLoaderTests {

    private let goal = GoalSummary(goalId: 7, eventName: "goal.7", limitSeconds: 600, targetLabel: "All Apps", targetType: .total)

    private func makeLoader(
        goals: MockGoalService,
        settings: MockNudgeSettingsService,
        user: UUID? = userId
    ) -> SupabaseMonitoringInputsLoader {
        SupabaseMonitoringInputsLoader(goalService: goals, settingsService: settings, currentUserId: { user })
    }

    @Test func enabledSessionTimeoutPassesMinutes() async throws {
        let goals = MockGoalService()
        goals.summaries = [goal]
        let settings = MockNudgeSettingsService()
        settings.settingsToReturn.sessionTimeoutMinutes = 90

        let inputs = try await makeLoader(goals: goals, settings: settings).loadMonitoringInputs()

        #expect(inputs == MonitoringInputs(goals: [goal], sessionTimeoutMinutes: 90))
    }

    @Test func disabledSessionTimeoutPassesNil() async throws {
        let settings = MockNudgeSettingsService()
        settings.settingsToReturn.sessionTimeoutEnabled = false

        let inputs = try await makeLoader(goals: MockGoalService(), settings: settings).loadMonitoringInputs()

        #expect(inputs.sessionTimeoutMinutes == nil)
    }

    /// ADR-055: a failed settings fetch is a failed load — never defaults.
    @Test func settingsFetchFailureThrows() async {
        let settings = MockNudgeSettingsService()
        settings.fetchError = TestFailure()
        await #expect(throws: TestFailure.self) {
            try await makeLoader(goals: MockGoalService(), settings: settings).loadMonitoringInputs()
        }
    }

    @Test func goalFetchFailureThrows() async {
        let goals = MockGoalService()
        goals.error = TestFailure()
        await #expect(throws: TestFailure.self) {
            try await makeLoader(goals: goals, settings: MockNudgeSettingsService()).loadMonitoringInputs()
        }
    }

    @Test func signedOutThrows() async {
        await #expect(throws: SupabaseMonitoringInputsLoader.LoadError.self) {
            try await makeLoader(goals: MockGoalService(), settings: MockNudgeSettingsService(), user: nil)
                .loadMonitoringInputs()
        }
    }
}

// MARK: - SettingsViewModel — nudge settings

@MainActor
private final class StubProfileService: ProfileServiceProtocol {
    var profile = Profile(
        userId: userId, firstName: "Grace", lastName: "Hopper",
        phoneNumber: "+18015551234", timeZone: "America/Denver", weekStart: 0
    )
    var fetchError: Error?
    var updateError: Error?
    var updateCalls = 0

    func fetchProfile(userId: UUID) async throws -> Profile {
        if let fetchError { throw fetchError }
        return profile
    }

    func updateProfile(userId: UUID, firstName: String, lastName: String, phoneNumber: String?) async throws {
        updateCalls += 1
        if let updateError { throw updateError }
    }
}

@MainActor
private final class StubFriendService: FriendServiceProtocol {
    var friends: [Friend] = []
    var error: Error?

    func fetchFriends(userId: UUID) async throws -> [Friend] {
        if let error { throw error }
        return friends
    }
    func addFriend(userId: UUID, name: String, phoneNumber: String) async throws {}
    func deleteFriend(id: Int) async throws {}
    func updateFriendName(id: Int, name: String) async throws {}
    func fetchNudgeHistory(friendId: Int) async throws -> [Nudge] { [] }
    func fetchFriendId(forNudgeId nudgeId: Int) async throws -> Int? { nil }
}

@MainActor
private final class SpyMonitoringService: MonitoringRegistrationServiceProtocol {
    var goalDidChangeCalls = 0
    func goalDidChange() { goalDidChangeCalls += 1 }
}

private func friend(id: Int, status: FriendStatus) -> Friend {
    Friend(
        id: id, userId: userId, friendName: "F\(id)", friendPhoneNumber: "+1801555000\(id)",
        status: status, invitationTimestamp: Date(timeIntervalSince1970: 0)
    )
}

@Suite("SettingsViewModel — nudge settings")
@MainActor
struct SettingsNudgeSettingsTests {

    @MainActor
    private struct Harness {
        let profile: StubProfileService
        let settings: MockNudgeSettingsService
        let friends: StubFriendService
        let monitoring: SpyMonitoringService
        let defaults: UserDefaults

        init() {
            profile = StubProfileService()
            settings = MockNudgeSettingsService()
            friends = StubFriendService()
            monitoring = SpyMonitoringService()
            defaults = makeDefaults()
        }

        func makeViewModel() -> SettingsViewModel {
            SettingsViewModel(
                profileService: profile,
                nudgeSettingsService: settings,
                friendService: friends,
                monitoringService: monitoring,
                defaults: defaults
            )
        }
    }

    private func loaded(_ h: Harness) async -> SettingsViewModel {
        let vm = h.makeViewModel()
        await vm.load(userId: userId, email: "grace@example.com")
        return vm
    }

    // MARK: Load

    @Test func loadPopulatesNudgeSettingsAndWritesAppGroup() async {
        let h = Harness()
        h.settings.settingsToReturn.goalBreachEnabled = true
        h.settings.settingsToReturn.sessionTimeoutMinutes = 30

        let vm = await loaded(h)

        #expect(vm.nudgeSettings.goalBreachEnabled == true)
        #expect(vm.nudgeSettings.sessionTimeoutMinutes == 30)
        #expect(vm.nudgeSettingsLoaded)
        #expect(vm.hasChanges == false)
        #expect(vm.errorMessage == nil)
        #expect(NudgeTriggerSettings.load(from: h.defaults).goalBreachEnabled == true)
    }

    @Test func settingsLoadFailureBlocksEditingAndKeepsAppGroup() async {
        let h = Harness()
        h.settings.fetchError = TestFailure()

        let vm = await loaded(h)

        #expect(vm.nudgeSettingsLoaded == false)
        #expect(vm.errorMessage != nil)
        // Profile still loads.
        #expect(vm.firstName == "Grace")
        // Nothing is written from data we do not have.
        #expect(h.defaults.data(forKey: AppGroupKeys.nudgeSettings) == nil)
        // Defaults standing in for the failed load must never be saved over the row.
        vm.nudgeSettings.goalBreachEnabled = true
        #expect(vm.hasChanges == false)
        #expect(vm.canSave == false)
    }

    // MARK: Dirty tracking

    @Test func changingASettingMakesItDirty() async {
        let h = Harness()
        let vm = await loaded(h)

        vm.nudgeSettings.sessionTimeoutMinutes = 120
        #expect(vm.hasChanges)
        #expect(vm.canSave)

        vm.nudgeSettings.sessionTimeoutMinutes = 60
        #expect(vm.hasChanges == false)
    }

    // MARK: Save paths

    @Test func onlySettingsChangedSavesSettingsOnly() async {
        let h = Harness()
        let vm = await loaded(h)
        vm.nudgeSettings.goalBreachEnabled = true

        await vm.save(userId: userId)

        #expect(h.profile.updateCalls == 0)
        #expect(h.settings.saved.count == 1)
        #expect(h.settings.saved.first?.goalBreachEnabled == true)
        #expect(h.settings.savedUserIds == [userId])
        #expect(h.monitoring.goalDidChangeCalls == 1)
        #expect(NudgeTriggerSettings.load(from: h.defaults).goalBreachEnabled == true)
        #expect(vm.didSave)
        #expect(vm.errorMessage == nil)
        #expect(vm.hasChanges == false)
    }

    @Test func onlyProfileChangedSavesProfileOnly() async {
        let h = Harness()
        let vm = await loaded(h)
        vm.firstName = "Ada"

        await vm.save(userId: userId)

        #expect(h.profile.updateCalls == 1)
        #expect(h.settings.saved.isEmpty)
        #expect(h.monitoring.goalDidChangeCalls == 0)
        #expect(vm.didSave)
        #expect(vm.hasChanges == false)
    }

    @Test func bothChangedSavesBoth() async {
        let h = Harness()
        let vm = await loaded(h)
        vm.firstName = "Ada"
        vm.nudgeSettings.sessionTimeoutEnabled = false

        await vm.save(userId: userId)

        #expect(h.profile.updateCalls == 1)
        #expect(h.settings.saved.count == 1)
        #expect(h.monitoring.goalDidChangeCalls == 1)
        #expect(vm.didSave)
        #expect(vm.hasChanges == false)
    }

    @Test func settingsSaveFailureChangesNothingLocally() async {
        let h = Harness()
        let vm = await loaded(h)
        let appGroupBefore = h.defaults.data(forKey: AppGroupKeys.nudgeSettings)
        h.settings.saveError = TestFailure()
        vm.nudgeSettings.goalBreachEnabled = true

        await vm.save(userId: userId)

        #expect(h.monitoring.goalDidChangeCalls == 0)
        #expect(h.defaults.data(forKey: AppGroupKeys.nudgeSettings) == appGroupBefore)
        #expect(NudgeTriggerSettings.load(from: h.defaults).goalBreachEnabled == false)
        #expect(vm.errorMessage != nil)
        #expect(vm.didSave == false)
        #expect(vm.isSaving == false)
        // The edit is kept so the user can retry.
        #expect(vm.nudgeSettings.goalBreachEnabled == true)
        #expect(vm.hasChanges)
    }

    @Test func profileFailureStillSavesSettings() async {
        let h = Harness()
        let vm = await loaded(h)
        h.profile.updateError = TestFailure()
        vm.firstName = "Ada"
        vm.nudgeSettings.goalBreachEnabled = true

        await vm.save(userId: userId)

        #expect(h.settings.saved.count == 1)
        #expect(h.monitoring.goalDidChangeCalls == 1)
        #expect(vm.errorMessage != nil)
        #expect(vm.didSave == false)
        // Only the profile is still dirty.
        #expect(vm.hasChanges)
        vm.firstName = "Grace"
        #expect(vm.hasChanges == false)
    }

    /// A blank profile field must not block saving an unrelated nudge setting (e.g. the
    /// profile failed to load), but must still block saving the profile itself.
    @Test func invalidUntouchedProfileDoesNotBlockSettingsSave() async {
        let h = Harness()
        h.profile.fetchError = TestFailure()
        let vm = await loaded(h)
        vm.nudgeSettings.goalBreachEnabled = true

        #expect(vm.canSave)
        await vm.save(userId: userId)

        #expect(h.profile.updateCalls == 0)
        #expect(h.settings.saved.count == 1)
    }

    @Test func dailyReportTimeBindingKeepsHourAndMinute() async {
        let h = Harness()
        let vm = await loaded(h)
        let cal = Calendar.current
        let picked = cal.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 21, minute: 40, second: 33))!

        vm.dailyReportDate = picked

        #expect(vm.nudgeSettings.dailyReportTime == TimeOfDay(hour: 21, minute: 40))
        #expect(cal.component(.hour, from: vm.dailyReportDate) == 21)
        #expect(cal.component(.minute, from: vm.dailyReportDate) == 40)
    }

    // MARK: Friends note

    @Test func noFriendsShowsNote() async {
        let h = Harness()
        let vm = await loaded(h)
        #expect(vm.showsNoFriendsNote)
    }

    @Test func onlyPendingFriendsShowsNote() async {
        let h = Harness()
        h.friends.friends = [friend(id: 1, status: .pending)]
        let vm = await loaded(h)
        #expect(vm.showsNoFriendsNote)
    }

    @Test func acceptedFriendHidesNote() async {
        let h = Harness()
        h.friends.friends = [friend(id: 1, status: .pending), friend(id: 2, status: .accepted)]
        let vm = await loaded(h)
        #expect(vm.showsNoFriendsNote == false)
    }

    /// Unknown is not "none": a failed friends fetch does not claim the user has no friends.
    @Test func friendsFetchFailureHidesNote() async {
        let h = Harness()
        h.friends.error = TestFailure()
        let vm = await loaded(h)
        #expect(vm.showsNoFriendsNote == false)
        #expect(vm.errorMessage == nil)
    }

    @Test func noteHiddenBeforeLoad() {
        #expect(Harness().makeViewModel().showsNoFriendsNote == false)
    }
}

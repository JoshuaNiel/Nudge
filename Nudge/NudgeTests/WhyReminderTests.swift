import Testing
import Foundation
import UserNotifications
@testable import Nudge

// Phase 4 — Why-reminders & goal notifications (v2). See docs/specs/phase-4-notifications.md.

// MARK: - Helpers

private func freshDefaults(_ name: String) -> UserDefaults {
    let suite = "test.whyreminders.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private func goal(id: Int = 42, label: String = "Instagram", limit: Int = 7200) -> GoalSummary {
    GoalSummary(
        goalId: id,
        eventName: MonitoringPlan.goalEventBase(goalId: id),
        limitSeconds: limit,
        targetLabel: label,
        targetType: .app
    )
}

private let userA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

private func why(_ id: Int, goal: Int = 42, _ message: String = "Be present", percent: Int = 80) -> WhyReminder {
    WhyReminder(id: id, userId: userA, goalId: goal, message: message, notifyPercent: percent)
}

private struct Offline: Error {}

// MARK: - Mocks

@MainActor
private final class MockReminderService: ReminderServiceProtocol {
    var reminders: [WhyReminder] = []
    var fetchError: Error?
    var writeError: Error?
    var fetchCount = 0
    var added: [(goalId: Int, message: String, percent: Int)] = []
    var updated: [(id: Int, message: String, percent: Int)] = []
    var deletedIds: [Int] = []
    private var nextId = 900

    func fetchReminders(userId: UUID) async throws -> [WhyReminder] {
        fetchCount += 1
        if let fetchError { throw fetchError }
        return reminders
    }

    func addReminder(userId: UUID, goalId: Int, message: String, notifyPercent: Int) async throws -> WhyReminder {
        if let writeError { throw writeError }
        added.append((goalId, message, notifyPercent))
        nextId += 1
        return WhyReminder(id: nextId, userId: userId, goalId: goalId, message: message, notifyPercent: notifyPercent)
    }

    func updateReminder(id: Int, userId: UUID, message: String, notifyPercent: Int) async throws -> WhyReminder {
        if let writeError { throw writeError }
        updated.append((id, message, notifyPercent))
        let goalId = reminders.first { $0.id == id }?.goalId ?? 42
        return WhyReminder(id: id, userId: userId, goalId: goalId, message: message, notifyPercent: notifyPercent)
    }

    func deleteReminder(id: Int, userId: UUID) async throws {
        if let writeError { throw writeError }
        deletedIds.append(id)
    }
}

@MainActor
private final class SpyReminderWriter: WhyReminderAppGroupWriting {
    var writes: [[WhyReminder]] = []
    func write(_ reminders: [WhyReminder]) { writes.append(reminders) }
}

@MainActor
private final class MockPermissionProvider: NotificationPermissionProviding {
    var status: NotificationPermissionStatus = .notAsked
    var statusAfterRequest: NotificationPermissionStatus = .allowed
    var requestError: Error?
    var requestCount = 0
    var statusCount = 0

    func currentStatus() async -> NotificationPermissionStatus {
        statusCount += 1
        return status
    }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        if let requestError { throw requestError }
        status = statusAfterRequest
        return statusAfterRequest == .allowed
    }
}

// MARK: - Model coding

@Suite("Why-reminders — model coding")
@MainActor
struct WhyReminderCodingTests {

    @Test func decodesFromSnakeCaseRow() throws {
        let json = """
        {"id": 5, "user_id": "\(userA.uuidString)", "goal_id": 42, "message": "Be present", "notify_percent": 70}
        """.data(using: .utf8)!
        let reminder = try JSONDecoder().decode(WhyReminder.self, from: json)
        #expect(reminder.id == 5)
        #expect(reminder.userId == userA)
        #expect(reminder.goalId == 42)
        #expect(reminder.message == "Be present")
        #expect(reminder.notifyPercent == 70)
    }

    @Test func encodesSnakeCaseKeys() throws {
        let data = try JSONEncoder().encode(why(5))
        let keys = Set((try JSONSerialization.jsonObject(with: data) as! [String: Any]).keys)
        #expect(keys == ["id", "user_id", "goal_id", "message", "notify_percent"])
    }

    @Test func insertEncodesOwnerGoalMessageAndPercent() throws {
        let insert = WhyReminderInsert(userId: userA, goalId: 42, message: "Sleep", notifyPercent: 50)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(insert)) as! [String: Any]
        #expect(Set(object.keys) == ["user_id", "goal_id", "message", "notify_percent"])
        #expect(object["goal_id"] as? Int == 42)
        #expect(object["notify_percent"] as? Int == 50)
    }

    /// The owner and the goal are never rewritten by an edit (the migration also
    /// grants UPDATE on only these two columns).
    @Test func updateEncodesOnlyMessageAndPercent() throws {
        let update = WhyReminderUpdate(message: "Sleep", notifyPercent: 50)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as! [String: Any]
        #expect(Set(object.keys) == ["message", "notify_percent"])
    }
}

// MARK: - Validation

@Suite("Why-reminders — validation")
@MainActor
struct WhyReminderValidationTests {

    @Test func blankMessageIsRejected() {
        #expect(WhyReminderRules.messageError("") != nil)
        #expect(WhyReminderRules.messageError("   \n\t ") != nil)
    }

    @Test func messageIsTrimmed() {
        #expect(WhyReminderRules.normalizedMessage("  Be present \n") == "Be present")
        #expect(WhyReminderRules.messageError("  Be present \n") == nil)
    }

    @Test func fiveHundredCharactersAllowed() {
        #expect(WhyReminderRules.messageError(String(repeating: "a", count: 500)) == nil)
    }

    @Test func fiveHundredOneCharactersRejected() {
        #expect(WhyReminderRules.messageError(String(repeating: "a", count: 501)) != nil)
    }

    /// Surrounding whitespace does not count toward the limit (it is trimmed on save).
    @Test func lengthIsMeasuredAfterTrimming() {
        #expect(WhyReminderRules.messageError("  " + String(repeating: "a", count: 500) + "  ") == nil)
    }

    /// Postgres `varchar(500)` counts code points, not grapheme clusters. A family emoji
    /// is one Character but seven code points; counting Characters would let a message
    /// through that the database then rejects.
    @Test func lengthCountsUnicodeScalarsLikePostgres() {
        let family = "👨‍👩‍👧‍👦"
        #expect(family.count == 1)
        #expect(WhyReminderRules.length(of: family) == 7)
        let tooLong = String(repeating: family, count: 72) // 504 code points, 72 characters
        #expect(WhyReminderRules.messageError(tooLong) != nil)
    }

    @Test(arguments: [0, 5, 9, 15, 95, 101, 110, -10])
    func invalidPercentsRejected(percent: Int) {
        #expect(!WhyReminderRules.isValidPercent(percent))
    }

    @Test(arguments: [10, 20, 50, 80, 90, 100])
    func validPercentsAccepted(percent: Int) {
        #expect(WhyReminderRules.isValidPercent(percent))
    }

    @Test func allowedPercentsMatchMilestones() {
        #expect(WhyReminderRules.allowedPercents == [10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
        #expect(WhyReminderRules.allowedPercents == MonitoringPlan.milestonePercents)
        #expect(WhyReminderRules.defaultPercent == 80)
    }

    @Test func percentCaption() {
        #expect(WhyReminderRules.percentCaption(80) == "at 80%")
    }
}

// MARK: - byGoal payload

@Suite("Why-reminders — byGoal payload")
@MainActor
struct WhyReminderPayloadTests {

    @Test func encodesAsNestedStringKeyedJSON() throws {
        let byGoal: WhyRemindersByGoal = [42: [80: ["Be present"], 100: ["Sleep"]]]
        let data = try #require(WhyReminderPayload.encode(byGoal))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: [String: [String]]]
        #expect(object == ["42": ["80": ["Be present"], "100": ["Sleep"]]])
    }

    @Test func roundTrips() throws {
        let byGoal: WhyRemindersByGoal = [1: [10: ["a", "b"]], 2: [100: ["c"]]]
        let data = try #require(WhyReminderPayload.encode(byGoal))
        #expect(WhyReminderPayload.decode(data) == byGoal)
    }

    @Test func garbageDecodesAsNil() {
        #expect(WhyReminderPayload.decode(Data("nope".utf8)) == nil)
    }

    @Test func buildsFromReminderList() {
        let reminders = [
            why(3, goal: 42, "Kids", percent: 80),
            why(1, goal: 42, "Sleep", percent: 80),
            why(2, goal: 42, "Read", percent: 100),
            why(4, goal: 7, "Walk", percent: 50),
        ]
        let byGoal = WhyReminderPayload.byGoal(from: reminders)
        // Ordered by id within (goal, percent) so rotation order is stable no matter
        // what order Supabase returns rows in.
        #expect(byGoal == [42: [80: ["Sleep", "Kids"], 100: ["Read"]], 7: [50: ["Walk"]]])
    }

    @Test func buildIsOrderIndependent() {
        let reminders = [why(1, "a"), why(2, "b"), why(3, "c")]
        #expect(WhyReminderPayload.byGoal(from: reminders) == WhyReminderPayload.byGoal(from: reminders.reversed()))
    }

    @Test func emptyListBuildsEmptyPayload() {
        #expect(WhyReminderPayload.byGoal(from: []).isEmpty)
    }

    @Test func storeWritesAndReads() {
        let store = WhyReminderStore(defaults: freshDefaults("storeWritesAndReads"))
        store.write([42: [80: ["Be present"]]])
        #expect(store.byGoal() == [42: [80: ["Be present"]]])
        #expect(store.messages(goalId: 42, percent: 80) == ["Be present"])
        #expect(store.messages(goalId: 42, percent: 90).isEmpty)
        #expect(store.messages(goalId: 9, percent: 80).isEmpty)
    }

    @Test func storeUsesTheAppGroupKey() {
        let defaults = freshDefaults("storeKey")
        WhyReminderStore(defaults: defaults).write([1: [10: ["x"]]])
        #expect(defaults.data(forKey: AppGroupKeys.remindersByGoal) != nil)
        #expect(AppGroupKeys.remindersByGoal == "nudge.reminders.byGoal")
        #expect(AppGroupKeys.remindersRoundRobin == "nudge.reminders.rr")
    }

    @Test func unreadableStoreReadsEmpty() {
        let defaults = freshDefaults("unreadable")
        defaults.set(Data("garbage".utf8), forKey: AppGroupKeys.remindersByGoal)
        #expect(WhyReminderStore(defaults: defaults).byGoal().isEmpty)
    }

    @Test func clearRemovesPayloadAndRotation() {
        let defaults = freshDefaults("clear")
        let store = WhyReminderStore(defaults: defaults)
        store.write([42: [80: ["a", "b"]]])
        _ = store.nextMessage(goalId: 42, percent: 80)
        store.clear()
        #expect(defaults.object(forKey: AppGroupKeys.remindersByGoal) == nil)
        #expect(defaults.object(forKey: AppGroupKeys.remindersRoundRobin) == nil)
    }

    /// Why-reminders are delivered outside the monitoring catalog: they must never
    /// influence the registration signature (editing a why must not reset progress).
    @Test func payloadIsNotPartOfTheMonitoringSignature() {
        let defaults = freshDefaults("signature")
        let goals = [goal()]
        let before = MonitoringPlan.signature(for: goals)
        WhyReminderStore(defaults: defaults).write([42: [80: ["Be present"]]])
        #expect(MonitoringPlan.signature(for: goals) == before)
    }
}

// MARK: - Round-robin

@Suite("Why-reminders — round-robin selection")
@MainActor
struct WhyReminderRotationTests {

    @Test func noMessagesSelectsNothing() {
        #expect(WhyReminderRotation.select(count: 0, storedIndex: nil) == nil)
        #expect(WhyReminderRotation.select(count: 0, storedIndex: 3) == nil)
    }

    @Test func singleMessageAlwaysSelected() {
        #expect(WhyReminderRotation.select(count: 1, storedIndex: nil) == .init(index: 0, next: 0))
        #expect(WhyReminderRotation.select(count: 1, storedIndex: 0) == .init(index: 0, next: 0))
    }

    @Test func multipleMessagesRotate() {
        #expect(WhyReminderRotation.select(count: 3, storedIndex: nil) == .init(index: 0, next: 1))
        #expect(WhyReminderRotation.select(count: 3, storedIndex: 1) == .init(index: 1, next: 2))
        #expect(WhyReminderRotation.select(count: 3, storedIndex: 2) == .init(index: 2, next: 0))
    }

    /// A why was deleted since the index was stored: wrap instead of going out of bounds.
    @Test func indexBeyondCountWraps() {
        #expect(WhyReminderRotation.select(count: 2, storedIndex: 5) == .init(index: 1, next: 0))
        #expect(WhyReminderRotation.select(count: 2, storedIndex: 2) == .init(index: 0, next: 1))
    }

    @Test func negativeIndexStartsOver() {
        #expect(WhyReminderRotation.select(count: 3, storedIndex: -4) == .init(index: 0, next: 1))
    }

    @Test func keyIsPerGoalAndPercent() {
        #expect(WhyReminderRotation.key(goalId: 42, percent: 80) == "42.80")
        #expect(WhyReminderRotation.key(goalId: 42, percent: 80) != WhyReminderRotation.key(goalId: 42, percent: 90))
    }

    @Test func storeRotatesAndPersistsAcrossCalls() {
        let defaults = freshDefaults("rotatePersist")
        WhyReminderStore(defaults: defaults).write([42: [80: ["a", "b", "c"]]])

        // A fresh store per call: the index must come from the App Group, as it does
        // across separate extension launches.
        let picks = (0..<4).map { _ in WhyReminderStore(defaults: defaults).nextMessage(goalId: 42, percent: 80) }
        #expect(picks == ["a", "b", "c", "a"])
    }

    @Test func rotationIsIndependentPerGoalAndPercent() {
        let store = WhyReminderStore(defaults: freshDefaults("independent"))
        store.write([42: [80: ["a", "b"], 100: ["x", "y"]], 7: [80: ["m", "n"]]])
        #expect(store.nextMessage(goalId: 42, percent: 80) == "a")
        #expect(store.nextMessage(goalId: 42, percent: 80) == "b")
        #expect(store.nextMessage(goalId: 42, percent: 100) == "x")
        #expect(store.nextMessage(goalId: 7, percent: 80) == "m")
    }

    @Test func storeWrapsAfterADeletion() {
        let store = WhyReminderStore(defaults: freshDefaults("wrapDeletion"))
        store.write([42: [80: ["a", "b", "c"]]])
        _ = store.nextMessage(goalId: 42, percent: 80) // a
        _ = store.nextMessage(goalId: 42, percent: 80) // b → stored index 2
        store.write([42: [80: ["a", "b"]]])          // "c" deleted
        #expect(store.nextMessage(goalId: 42, percent: 80) == "a")
        #expect(store.nextMessage(goalId: 42, percent: 80) == "b")
    }

    @Test func noWhyReturnsNilAndStoresNothing() {
        let defaults = freshDefaults("noWhy")
        let store = WhyReminderStore(defaults: defaults)
        #expect(store.nextMessage(goalId: 42, percent: 80) == nil)
        #expect(defaults.object(forKey: AppGroupKeys.remindersRoundRobin) == nil)
    }
}

// MARK: - Notification composition

@Suite("Why-reminders — notification composition")
@MainActor
struct GoalNotificationComposerTests {

    @Test func milestoneTitleCopy() {
        #expect(NudgeMessages.milestoneReminderTitle(percent: 80, label: "Instagram") == "You're at 80% of your Instagram limit")
    }

    @Test func milestoneWithWhy() {
        let content = GoalNotificationComposer.milestone(goal: goal(), percent: 80, why: "Be present with my kids")
        #expect(content == GoalNotificationContent(
            title: "You're at 80% of your Instagram limit",
            body: "Be present with my kids"
        ))
    }

    @Test func milestoneWithoutWhyPostsNothing() {
        #expect(GoalNotificationComposer.milestone(goal: goal(), percent: 80, why: nil) == nil)
    }

    @Test func limitReachedWithWhyUsesTheWhyAsBody() {
        let content = GoalNotificationComposer.limitReached(goal: goal(), why: "Sleep matters")
        #expect(content == GoalNotificationContent(title: "You've hit your Instagram limit", body: "Sleep matters"))
    }

    @Test func limitReachedWithoutWhyIsTheGenericNotification() {
        let content = GoalNotificationComposer.limitReached(goal: goal(), why: nil)
        #expect(content == GoalNotificationContent(
            title: "You've hit your Instagram limit",
            body: "You set a 2h daily limit on Instagram."
        ))
    }
}

// MARK: - Foreground sync

@Suite("Why-reminders — foreground sync")
@MainActor
struct WhyReminderSyncTests {

    @Test func successfulFetchWritesTheAppGroup() async {
        let service = MockReminderService()
        service.reminders = [why(1), why(2, goal: 7)]
        let writer = SpyReminderWriter()
        let sync = WhyReminderSync(service: service, writer: writer)

        let ok = await sync.refresh(userId: userA)

        #expect(ok)
        #expect(writer.writes.count == 1)
        #expect(writer.writes.first?.map(\.id) == [1, 2])
    }

    /// An empty list from a *successful* fetch is real ("no whys") and must be written.
    @Test func successfulEmptyFetchWritesEmpty() async {
        let writer = SpyReminderWriter()
        let sync = WhyReminderSync(service: MockReminderService(), writer: writer)
        #expect(await sync.refresh(userId: userA))
        #expect(writer.writes.count == 1)
        #expect(writer.writes.first?.isEmpty == true)
    }

    @Test func failedFetchDoesNotOverwrite() async {
        let service = MockReminderService()
        service.fetchError = Offline()
        let writer = SpyReminderWriter()
        let sync = WhyReminderSync(service: service, writer: writer)

        let ok = await sync.refresh(userId: userA)

        #expect(!ok)
        #expect(writer.writes.isEmpty)
    }

    /// End to end against a real App Group store: yesterday's copy survives a failure.
    @Test func failedFetchKeepsTheStoredCopy() async {
        let defaults = freshDefaults("syncFailure")
        let writer = AppGroupWhyReminderWriter(defaults: defaults)
        writer.write([why(1, "Be present")])

        let service = MockReminderService()
        service.fetchError = Offline()
        await WhyReminderSync(service: service, writer: writer).refresh(userId: userA)

        #expect(WhyReminderStore(defaults: defaults).byGoal() == [42: [80: ["Be present"]]])
    }
}

// MARK: - ViewModel

@Suite("Why-reminders — ViewModel")
@MainActor
struct WhyRemindersViewModelTests {

    private func loadedVM(
        _ reminders: [WhyReminder],
        goalId: Int = 42
    ) async -> (WhyRemindersViewModel, MockReminderService, SpyReminderWriter) {
        let service = MockReminderService()
        service.reminders = reminders
        let writer = SpyReminderWriter()
        let vm = WhyRemindersViewModel(goalId: goalId, service: service, writer: writer)
        await vm.load(userId: userA)
        return (vm, service, writer)
    }

    @Test func loadShowsOnlyThisGoalsWhysSortedByPercent() async {
        let (vm, _, _) = await loadedVM([
            why(1, goal: 42, "late", percent: 90),
            why(2, goal: 7, "other goal", percent: 50),
            why(3, goal: 42, "early", percent: 30),
        ])
        #expect(vm.reminders.map(\.id) == [3, 1])
        #expect(vm.hasLoaded)
        #expect(vm.loadError == nil)
        #expect(!vm.isLoading)
    }

    @Test func loadFailureSetsErrorAndDoesNotWrite() async {
        let service = MockReminderService()
        service.fetchError = Offline()
        let writer = SpyReminderWriter()
        let vm = WhyRemindersViewModel(goalId: 42, service: service, writer: writer)

        await vm.load(userId: userA)

        #expect(vm.loadError != nil)
        #expect(!vm.hasLoaded)
        #expect(vm.reminders.isEmpty)
        #expect(writer.writes.isEmpty)
    }

    @Test func addTrimsSavesAndRefreshesTheAppGroupWithEveryGoal() async {
        let (vm, service, writer) = await loadedVM([why(1, goal: 7, "other goal", percent: 50)])
        writer.writes.removeAll()

        let error = await vm.add(userId: userA, message: "  Be present  ", percent: 70)

        #expect(error == nil)
        #expect(service.added.count == 1)
        #expect(service.added.first?.message == "Be present")
        #expect(service.added.first?.goalId == 42)
        #expect(service.added.first?.percent == 70)
        #expect(vm.reminders.map(\.message) == ["Be present"])
        // The App Group copy covers every goal, not just the one on screen.
        #expect(writer.writes.count == 1)
        #expect(Set(writer.writes.last?.map(\.goalId) ?? []) == [7, 42])
    }

    @Test func addRejectsInvalidInputWithoutCallingTheService() async {
        let (vm, service, writer) = await loadedVM([])
        writer.writes.removeAll()

        #expect(await vm.add(userId: userA, message: "   ", percent: 80) != nil)
        #expect(await vm.add(userId: userA, message: String(repeating: "a", count: 501), percent: 80) != nil)
        #expect(await vm.add(userId: userA, message: "ok", percent: 85) != nil)

        #expect(service.added.isEmpty)
        #expect(writer.writes.isEmpty)
    }

    @Test func addFailureReturnsErrorAndDoesNotWrite() async {
        let (vm, service, writer) = await loadedVM([])
        writer.writes.removeAll()
        service.writeError = Offline()

        let error = await vm.add(userId: userA, message: "Be present", percent: 80)

        #expect(error != nil)
        #expect(vm.reminders.isEmpty)
        #expect(writer.writes.isEmpty)
    }

    /// Writing before the full list loaded would replace every other goal's whys in
    /// the App Group with just this one.
    @Test func addBeforeLoadIsRefused() async {
        let service = MockReminderService()
        service.fetchError = Offline()
        let writer = SpyReminderWriter()
        let vm = WhyRemindersViewModel(goalId: 42, service: service, writer: writer)
        await vm.load(userId: userA)

        #expect(await vm.add(userId: userA, message: "Be present", percent: 80) != nil)
        #expect(service.added.isEmpty)
        #expect(writer.writes.isEmpty)
    }

    @Test func updateSavesAndRefreshesTheAppGroup() async {
        let original = why(1, "Old", percent: 80)
        let (vm, service, writer) = await loadedVM([original])
        writer.writes.removeAll()

        let error = await vm.update(original, userId: userA, message: " New ", percent: 100)

        #expect(error == nil)
        #expect(service.updated.first?.id == 1)
        #expect(service.updated.first?.message == "New")
        #expect(service.updated.first?.percent == 100)
        #expect(vm.reminders.map(\.message) == ["New"])
        #expect(vm.reminders.first?.notifyPercent == 100)
        #expect(writer.writes.count == 1)
        #expect(writer.writes.last?.first?.message == "New")
    }

    @Test func updateFailureKeepsTheOldValueAndDoesNotWrite() async {
        let original = why(1, "Old")
        let (vm, service, writer) = await loadedVM([original])
        writer.writes.removeAll()
        service.writeError = Offline()

        #expect(await vm.update(original, userId: userA, message: "New", percent: 80) != nil)
        #expect(vm.reminders.map(\.message) == ["Old"])
        #expect(writer.writes.isEmpty)
    }

    @Test func updateRejectsInvalidPercent() async {
        let original = why(1)
        let (vm, service, _) = await loadedVM([original])
        #expect(await vm.update(original, userId: userA, message: "ok", percent: 0) != nil)
        #expect(service.updated.isEmpty)
    }

    @Test func deleteRemovesAndRefreshesTheAppGroup() async {
        let (vm, service, writer) = await loadedVM([why(1), why(2)])
        writer.writes.removeAll()

        let ok = await vm.delete(vm.reminders[0], userId: userA)

        #expect(ok)
        #expect(service.deletedIds == [1])
        #expect(vm.reminders.map(\.id) == [2])
        #expect(writer.writes.count == 1)
        #expect(writer.writes.last?.map(\.id) == [2])
        #expect(vm.actionError == nil)
    }

    @Test func deleteFailureSetsErrorAndDoesNotWrite() async {
        let (vm, service, writer) = await loadedVM([why(1)])
        writer.writes.removeAll()
        service.writeError = Offline()

        let ok = await vm.delete(vm.reminders[0], userId: userA)

        #expect(!ok)
        #expect(vm.actionError != nil)
        #expect(vm.reminders.map(\.id) == [1])
        #expect(writer.writes.isEmpty)
    }
}

// MARK: - Notification permission

@Suite("Why-reminders — notification permission")
@MainActor
struct NotificationPermissionTests {

    @Test func mapsSystemStatus() {
        #expect(NotificationPermissionStatus(.authorized) == .allowed)
        #expect(NotificationPermissionStatus(.provisional) == .allowed)
        #expect(NotificationPermissionStatus(.ephemeral) == .allowed)
        #expect(NotificationPermissionStatus(.denied) == .off)
        #expect(NotificationPermissionStatus(.notDetermined) == .notAsked)
    }

    @Test func rowStateAllowed() {
        let state = NotificationRowState.make(.allowed)
        #expect(state.statusText == "Allowed")
        #expect(state.action == .none)
        #expect(state.actionTitle == nil)
    }

    @Test func rowStateOffOpensSettings() {
        let state = NotificationRowState.make(.off)
        #expect(state.statusText == "Off")
        #expect(state.action == .openSettings)
        #expect(state.actionTitle == "Open Settings")
    }

    @Test func rowStateNotAskedTurnsOn() {
        let state = NotificationRowState.make(.notAsked)
        #expect(state.statusText == "Not asked")
        #expect(state.action == .requestPermission)
        #expect(state.actionTitle == "Turn On")
    }

    @Test func rowStateWhileChecking() {
        let state = NotificationRowState.make(nil)
        #expect(state.action == .none)
        #expect(state.actionTitle == nil)
    }

    @Test func refreshReadsStatus() async {
        let provider = MockPermissionProvider()
        provider.status = .off
        let vm = NotificationSettingsViewModel(provider: provider)
        #expect(vm.status == nil)

        await vm.refresh()

        #expect(vm.status == .off)
        #expect(vm.rowState.action == .openSettings)
    }

    @Test func turnOnRequestsThenRefreshes() async {
        let provider = MockPermissionProvider()
        provider.status = .notAsked
        provider.statusAfterRequest = .allowed
        let vm = NotificationSettingsViewModel(provider: provider)
        await vm.refresh()

        await vm.turnOn()

        #expect(provider.requestCount == 1)
        #expect(vm.status == .allowed)
        #expect(!vm.isRequesting)
    }

    @Test func turnOnDeclinedShowsOff() async {
        let provider = MockPermissionProvider()
        provider.statusAfterRequest = .off
        let vm = NotificationSettingsViewModel(provider: provider)

        await vm.turnOn()

        #expect(vm.status == .off)
    }

    @Test func turnOnFailureStillRefreshes() async {
        let provider = MockPermissionProvider()
        provider.status = .notAsked
        provider.requestError = Offline()
        let vm = NotificationSettingsViewModel(provider: provider)

        await vm.turnOn()

        #expect(provider.statusCount >= 1)
        #expect(vm.status == .notAsked)
        #expect(!vm.isRequesting)
    }
}

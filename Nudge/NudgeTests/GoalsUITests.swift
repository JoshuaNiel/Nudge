import Testing
import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings
import SwiftUI
import Supabase
@testable import Nudge

// Phase 3b — Goals UI. See docs/specs/phase-3-goals.md (UI, edge cases, 3b notes).

// MARK: - Helpers

private func calendar(_ tz: String) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: tz)!
    return cal
}

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, in cal: Calendar) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
    return cal.date(from: c)!
}

/// Tokens are opaque `Codable` blobs; decoding a keyed `data` payload yields a token
/// that behaves like a real one for counting, hashing and round-tripping.
private func fakeToken<T>(_ seed: UInt8, as type: Token<T>.Type = Token<T>.self) throws -> Token<T> {
    let payload = Data(repeating: seed, count: 32).base64EncodedString()
    return try JSONDecoder().decode(Token<T>.self, from: Data(#"{"data":"\#(payload)"}"#.utf8))
}

private func appSelection(seeds: [UInt8]) throws -> FamilyActivitySelection {
    var selection = FamilyActivitySelection()
    selection.applicationTokens = Set(try seeds.map { try fakeToken($0, as: ApplicationToken.self) })
    return selection
}

private func encodedAppSelection(seed: UInt8 = 1) throws -> String {
    try #require(SelectionCodec.encode(try appSelection(seeds: [seed])))
}

private func goal(
    id: Int,
    type: GoalTargetType = .total,
    limit: Int = 3600,
    frequency: GoalFrequency = .daily,
    categoryId: Int? = nil,
    selection: String? = nil,
    label: String? = nil,
    temporary: Bool = false,
    start: String? = nil,
    end: String? = nil
) -> Goal {
    Goal(
        id: id, userId: UUID(), limitSeconds: limit, frequency: frequency, targetType: type,
        bundleId: nil, categoryId: categoryId, temporary: temporary, startDate: start, endDate: end,
        selection: selection, label: label
    )
}

private func category(id: Int, name: String = "Social", color: String = "#FF3B30", selection: String? = nil) -> AppCategory {
    AppCategory(id: id, userId: UUID(), name: name, color: color, selection: selection)
}

private let uniqueViolation = PostgrestError(code: "23505", message: "duplicate key value violates unique constraint")
private let checkViolation = PostgrestError(code: "23514", message: "new row violates check constraint")

// MARK: - Mocks

@MainActor
private final class MockGoalService: GoalServiceProtocol {
    var goals: [Goal] = []
    var fetchError: Error?
    var createError: Error?
    var deleteError: Error?
    var updateError: Error?
    var fetchCount = 0
    var created: [GoalInsert] = []
    var deletedIds: [Int] = []
    var updatedSelections: [(id: Int, selection: String)] = []

    func fetchGoals(userId: UUID) async throws -> [Goal] {
        fetchCount += 1
        if let fetchError { throw fetchError }
        return goals
    }

    func createGoal(_ goal: GoalInsert) async throws {
        if let createError { throw createError }
        created.append(goal)
    }

    func deleteGoal(id: Int, userId: UUID) async throws {
        if let deleteError { throw deleteError }
        deletedIds.append(id)
    }

    func updateGoalSelection(id: Int, userId: UUID, selection: String) async throws {
        if let updateError { throw updateError }
        updatedSelections.append((id, selection))
    }

    func fetchGoalSummaries(userId: UUID) async throws -> [GoalSummary] { [] }
}

@MainActor
private final class MockCategoryService: CategoryServiceProtocol {
    var categories: [AppCategory] = []
    var fetchError: Error?
    var saveError: Error?
    var deleteError: Error?
    var created: [(name: String, color: String, selection: String)] = []
    var updated: [(id: Int, name: String, color: String, selection: String)] = []
    var deletedIds: [Int] = []
    private var nextId = 100

    func fetchCategories(userId: UUID) async throws -> [AppCategory] {
        if let fetchError { throw fetchError }
        return categories
    }

    func createCategory(userId: UUID, name: String, color: String, selection: String) async throws -> AppCategory {
        if let saveError { throw saveError }
        created.append((name, color, selection))
        nextId += 1
        return AppCategory(id: nextId, userId: userId, name: name, color: color, selection: selection)
    }

    func updateCategory(id: Int, userId: UUID, name: String, color: String, selection: String) async throws -> AppCategory {
        if let saveError { throw saveError }
        updated.append((id, name, color, selection))
        return AppCategory(id: id, userId: userId, name: name, color: color, selection: selection)
    }

    func deleteCategory(id: Int, userId: UUID) async throws {
        if let deleteError { throw deleteError }
        deletedIds.append(id)
    }
}

@MainActor
private final class MockProgressReader: GoalProgressReading {
    var progress: [Int: Int] = [:]
    func todayProgress() -> [Int: Int] { progress }
}

@MainActor
private final class MockMonitoring: MonitoringRegistrationServiceProtocol {
    var calls = 0
    func goalDidChange() { calls += 1 }
}

private struct Offline: Error {}

// MARK: - App selection validator

@Suite("Goals UI — app selection validator")
@MainActor
struct AppSelectionValidatorTests {

    @Test func zeroAppsAsksForOne() {
        #expect(GoalTargetValidation.appSelectionError(applicationCount: 0, categoryCount: 0, webDomainCount: 0) == "Choose an app.")
    }

    @Test func exactlyOneAppIsValid() {
        #expect(GoalTargetValidation.appSelectionError(applicationCount: 1, categoryCount: 0, webDomainCount: 0) == nil)
    }

    @Test func twoAppsRejected() {
        #expect(GoalTargetValidation.appSelectionError(applicationCount: 2, categoryCount: 0, webDomainCount: 0) == "Choose only one app.")
    }

    @Test func appPlusCategoryRejected() {
        #expect(GoalTargetValidation.appSelectionError(applicationCount: 1, categoryCount: 1, webDomainCount: 0)
                == "Choose a single app, not a category or website.")
    }

    @Test func webDomainRejected() {
        #expect(GoalTargetValidation.appSelectionError(applicationCount: 0, categoryCount: 0, webDomainCount: 1)
                == "Choose a single app, not a category or website.")
        #expect(GoalTargetValidation.appSelectionError(applicationCount: 1, categoryCount: 0, webDomainCount: 1)
                == "Choose a single app, not a category or website.")
    }

    @Test func selectionOverloadCountsTokens() throws {
        #expect(GoalTargetValidation.appSelectionError(for: FamilyActivitySelection()) == "Choose an app.")
        #expect(GoalTargetValidation.appSelectionError(for: try appSelection(seeds: [1])) == nil)
        #expect(GoalTargetValidation.appSelectionError(for: try appSelection(seeds: [1, 2])) == "Choose only one app.")
    }
}

// MARK: - Label rules

@Suite("Goals UI — label rules")
@MainActor
struct GoalLabelRuleTests {

    @Test func blankLabelRejected() {
        #expect(GoalTargetValidation.labelError("") == "Enter a name for this app.")
        #expect(GoalTargetValidation.labelError("   \n ") == "Enter a name for this app.")
    }

    @Test func hundredCharactersAllowed() {
        #expect(GoalTargetValidation.labelError(String(repeating: "a", count: 100)) == nil)
    }

    @Test func overHundredRejected() {
        #expect(GoalTargetValidation.labelError(String(repeating: "a", count: 101)) == "Name must be 100 characters or fewer.")
    }

    @Test func lengthIsMeasuredAfterTrimming() {
        #expect(GoalTargetValidation.labelError("  " + String(repeating: "a", count: 100) + "  ") == nil)
        #expect(GoalTargetValidation.normalizedLabel("  Instagram \n") == "Instagram")
    }
}

// MARK: - Limit bounds

@Suite("Goals UI — limit bounds")
@MainActor
struct GoalLimitTests {

    @Test func secondsFromHoursAndMinutes() {
        #expect(GoalLimit.seconds(hours: 1, minutes: 30) == 5400)
        #expect(GoalLimit.seconds(hours: 0, minutes: 5) == 300)
    }

    @Test func minimumIsFiveMinutes() {
        #expect(GoalLimit.minimumSeconds == 300)
        #expect(GoalLimit.error(hours: 0, minutes: 0) == "Limit must be at least 5 minutes.")
        #expect(GoalLimit.error(hours: 0, minutes: 4) == "Limit must be at least 5 minutes.")
        #expect(GoalLimit.error(hours: 0, minutes: 5) == nil)
    }

    @Test func maximumIs23h59m() {
        #expect(GoalLimit.maximumSeconds == 23 * 3600 + 59 * 60)
        #expect(GoalLimit.error(hours: 23, minutes: 59) == nil)
        #expect(GoalLimit.error(hours: 24, minutes: 0) == "Limit can't be more than 23h 59m.")
    }

    @Test func outOfRangeComponentsRejected() {
        #expect(GoalLimit.error(hours: -1, minutes: 30) != nil)
        #expect(GoalLimit.error(hours: 1, minutes: 60) != nil)
    }

    @Test func limitTextIsPerDay() {
        #expect(GoalDisplay.limitText(seconds: 7200) == "2h / day")
        #expect(GoalDisplay.limitText(seconds: 5400) == "1h 30m / day")
        #expect(GoalDisplay.limitText(seconds: 300) == "5m / day")
    }
}

// MARK: - Temporary date range

@Suite("Goals UI — temporary date range")
@MainActor
struct GoalDateRangeTests {

    private let cal = calendar("America/Denver")
    private var now: Date { date(2026, 11, 14, 12, in: cal) }

    @Test func todayToTodayIsValid() {
        #expect(GoalDateRange.error(start: now, end: now, today: now, calendar: cal) == nil)
    }

    @Test func earlierTimeTodayStillCountsAsToday() {
        let morning = date(2026, 11, 14, 6, in: cal)
        #expect(GoalDateRange.error(start: morning, end: morning, today: now, calendar: cal) == nil)
    }

    @Test func startInThePastRejected() {
        let yesterday = date(2026, 11, 13, 23, 59, in: cal)
        #expect(GoalDateRange.error(start: yesterday, end: now, today: now, calendar: cal) == "Start date can't be in the past.")
    }

    @Test func endBeforeStartRejected() {
        let start = date(2026, 11, 20, in: cal)
        let end = date(2026, 11, 19, in: cal)
        #expect(GoalDateRange.error(start: start, end: end, today: now, calendar: cal) == "End date must be on or after the start date.")
    }

    @Test func dayStringsUseTheLocalCalendarDay() {
        let start = date(2026, 11, 14, 23, 30, in: cal)
        let end = date(2026, 11, 21, 0, 15, in: cal)
        let days = GoalDateRange.dayStrings(start: start, end: end, calendar: cal)
        #expect(days.start == "2026-11-14")
        #expect(days.end == "2026-11-21")
    }

    @Test func displayTextFormatsRange() {
        let text = GoalDateRange.displayText(start: "2026-11-14", end: "2026-11-21", calendar: cal, locale: Locale(identifier: "en_US"))
        #expect(text == "Nov 14 – Nov 21")
        #expect(GoalDateRange.displayText(start: "bad", end: "2026-11-21", calendar: cal, locale: Locale(identifier: "en_US")) == nil)
    }
}

// MARK: - Progress display

@Suite("Goals UI — progress display")
@MainActor
struct GoalProgressDisplayTests {

    @Test func captions() {
        #expect(GoalProgressDisplay.caption(percent: nil) == "Under 10%")
        #expect(GoalProgressDisplay.caption(percent: 0) == "Under 10%")
        #expect(GoalProgressDisplay.caption(percent: 10) == "≈ 10% used")
        #expect(GoalProgressDisplay.caption(percent: 50) == "≈ 50% used")
        #expect(GoalProgressDisplay.caption(percent: 90) == "≈ 90% used")
        #expect(GoalProgressDisplay.caption(percent: 100) == "Limit reached")
        #expect(GoalProgressDisplay.caption(percent: 130) == "Limit reached")
    }

    @Test func filledSteps() {
        #expect(GoalProgressDisplay.stepCount == 10)
        #expect(GoalProgressDisplay.filledSteps(percent: nil) == 0)
        #expect(GoalProgressDisplay.filledSteps(percent: -10) == 0)
        #expect(GoalProgressDisplay.filledSteps(percent: 0) == 0)
        #expect(GoalProgressDisplay.filledSteps(percent: 10) == 1)
        #expect(GoalProgressDisplay.filledSteps(percent: 55) == 5)
        #expect(GoalProgressDisplay.filledSteps(percent: 100) == 10)
        #expect(GoalProgressDisplay.filledSteps(percent: 250) == 10)
    }
}

// MARK: - Unique-violation mapping

@Suite("Goals UI — save error mapping")
@MainActor
struct SaveErrorMappingTests {

    @Test func goalUniqueViolation() {
        #expect(SaveErrorMessage.goal(for: uniqueViolation) == "You already have a daily goal for this.")
    }

    @Test func goalOtherErrorsAreGeneric() {
        #expect(SaveErrorMessage.goal(for: checkViolation) == "Couldn't save the goal. Please try again.")
        #expect(SaveErrorMessage.goal(for: URLError(.notConnectedToInternet)) == "Couldn't save the goal. Please try again.")
    }

    @Test func categoryUniqueViolation() {
        #expect(SaveErrorMessage.category(for: uniqueViolation) == "You already have a category with this name.")
    }

    @Test func categoryOtherErrorsAreGeneric() {
        #expect(SaveErrorMessage.category(for: checkViolation) == "Couldn't save the category. Please try again.")
        #expect(SaveErrorMessage.category(for: Offline()) == "Couldn't save the category. Please try again.")
    }

    @Test func detectsUniqueViolationCode() {
        #expect(SaveErrorMessage.isUniqueViolation(uniqueViolation))
        #expect(!SaveErrorMessage.isUniqueViolation(checkViolation))
        #expect(!SaveErrorMessage.isUniqueViolation(Offline()))
    }
}

// MARK: - Category palette + rules

@Suite("Goals UI — category palette")
@MainActor
struct CategoryPaletteTests {

    @Test func eightUniqueValidHexColors() {
        #expect(CategoryPalette.colors.count == 8)
        #expect(Set(CategoryPalette.colors).count == 8)
        for hex in CategoryPalette.colors {
            #expect(CategoryPalette.isValidHex(hex), "\(hex)")
            #expect(Color(hex: hex) != nil, "\(hex)")
        }
        #expect(CategoryPalette.colors.contains(CategoryPalette.defaultColor))
    }

    @Test func hexValidation() {
        #expect(CategoryPalette.isValidHex("#12AB9f"))
        #expect(!CategoryPalette.isValidHex("#12345"))
        #expect(!CategoryPalette.isValidHex("123456"))
        #expect(!CategoryPalette.isValidHex("#GGGGGG"))
        #expect(!CategoryPalette.isValidHex("#1234567"))
        #expect(!CategoryPalette.isValidHex(""))
    }
}

@Suite("Goals UI — category rules")
@MainActor
struct CategoryRulesTests {

    @Test func summaryText() {
        #expect(CategoryRules.summaryText(applicationCount: 3, categoryCount: 1) == "3 apps, 1 category")
        #expect(CategoryRules.summaryText(applicationCount: 1, categoryCount: 0) == "1 app, 0 categories")
        #expect(CategoryRules.summaryText(applicationCount: 0, categoryCount: 2) == "0 apps, 2 categories")
        #expect(CategoryRules.summaryText(applicationCount: 1, categoryCount: 0, webDomainCount: 2) == "1 app, 0 categories, 2 websites")
        #expect(CategoryRules.summaryText(applicationCount: 1, categoryCount: 0, webDomainCount: 1) == "1 app, 0 categories, 1 website")
    }

    @Test func summaryFromEncodedSelection() throws {
        #expect(CategoryRules.summaryText(encodedSelection: nil) == "—")
        #expect(CategoryRules.summaryText(encodedSelection: "garbage!!") == "—")
        let empty = try #require(SelectionCodec.encode(FamilyActivitySelection()))
        #expect(CategoryRules.summaryText(encodedSelection: empty) == "0 apps, 0 categories")
        #expect(CategoryRules.summaryText(encodedSelection: try encodedAppSelection()) == "1 app, 0 categories")
    }

    @Test func selectionRequiresAppOrCategory() {
        #expect(CategoryRules.selectionError(applicationCount: 0, categoryCount: 0, webDomainCount: 0) == "Choose at least one app or category.")
        #expect(CategoryRules.selectionError(applicationCount: 0, categoryCount: 0, webDomainCount: 3) == "Choose at least one app or category.")
        #expect(CategoryRules.selectionError(applicationCount: 1, categoryCount: 0, webDomainCount: 0) == nil)
        #expect(CategoryRules.selectionError(applicationCount: 0, categoryCount: 1, webDomainCount: 0) == nil)
    }

    @Test func nameRules() {
        #expect(CategoryRules.nameError("  ") == "Enter a name.")
        #expect(CategoryRules.nameError(String(repeating: "x", count: 100)) == nil)
        #expect(CategoryRules.nameError(String(repeating: "x", count: 101)) == "Name must be 100 characters or fewer.")
    }
}

// MARK: - Category insert/update coding

@Suite("Goals UI — category write models")
@MainActor
struct CategoryWriteModelTests {

    @Test func insertEncodesSnakeCase() throws {
        let insert = AppCategoryInsert(userId: UUID(), name: "Social", color: "#FF3B30", selection: "abc")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(insert)) as! [String: Any]
        #expect(json["user_id"] != nil)
        #expect(json["name"] as? String == "Social")
        #expect(json["color"] as? String == "#FF3B30")
        #expect(json["selection"] as? String == "abc")
        #expect(json["userId"] == nil)
    }

    @Test func updateDoesNotTouchOwner() throws {
        let update = AppCategoryUpdate(name: "Games", color: "#34C759", selection: "xyz")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as! [String: Any]
        #expect(Set(json.keys) == ["name", "color", "selection"])
    }
}

// MARK: - Goal usage report

@Suite("Goals UI — goal usage report")
@MainActor
struct GoalUsageTests {

    @Test func contextIsDistinct() {
        #expect(DeviceActivityReport.Context.goalUsage.rawValue == "GoalUsage")
        #expect(DeviceActivityReport.Context.goalUsage != .nudgeSummary)
    }

    @Test func sumsSegmentsAndRoundsOnce() {
        #expect(GoalUsageSummary.total(ofSegmentDurations: [1200.4, 1620.4]).totalSeconds == 2821)
        #expect(GoalUsageSummary.total(ofSegmentDurations: []).totalSeconds == 0)
        #expect(GoalUsageSummary.total(ofSegmentDurations: [-5]).totalSeconds == 0)
    }

    @Test func text() {
        #expect(GoalUsageSummary(totalSeconds: 2820).text == "47m used today")
        #expect(GoalUsageSummary(totalSeconds: 5400).text == "1h 30m used today")
        #expect(GoalUsageSummary(totalSeconds: 30).text == "< 1m used today")
        #expect(GoalUsageSummary(totalSeconds: 0).text == "No usage yet today")
    }

    @Test func filterIntervalIsTheWholeLocalDay() {
        let cal = calendar("America/Denver")
        let interval = GoalUsageDay.filterInterval(now: date(2026, 11, 14, 15, 30, in: cal), calendar: cal)
        #expect(interval.start == date(2026, 11, 14, 0, in: cal))
        #expect(interval.duration == 86_400)
    }

    @Test func filterIntervalSpansADSTDay() {
        let cal = calendar("America/Denver")
        // US DST ends 2026-11-01: that local day is 25 hours long.
        let interval = GoalUsageDay.filterInterval(now: date(2026, 11, 1, 9, in: cal), calendar: cal)
        #expect(interval.start == date(2026, 11, 1, 0, in: cal))
        #expect(interval.duration == 90_000)
    }
}

// MARK: - Goal list items

@Suite("Goals UI — goal list items")
@MainActor
struct GoalListItemTests {

    private let today = "2026-11-14"

    @Test func totalGoalIsActiveWithProgress() {
        let item = GoalListItem.make(goal: goal(id: 1, limit: 7200), categories: [], progress: [1: 50], today: today)
        #expect(item.title == "All Apps")
        #expect(item.target == .total)
        #expect(item.status == .active)
        #expect(item.percent == 50)
        #expect(item.caption == "≈ 50% used")
        #expect(item.limitText == "2h / day")
        #expect(item.selection == nil)
    }

    @Test func missingProgressReadsUnderTenPercent() {
        let item = GoalListItem.make(goal: goal(id: 1), categories: [], progress: [99: 70], today: today)
        #expect(item.percent == nil)
        #expect(item.caption == "Under 10%")
    }

    @Test func appGoalWithValidSelectionIsActive() throws {
        let item = GoalListItem.make(
            goal: goal(id: 2, type: .app, selection: try encodedAppSelection(), label: "Instagram"),
            categories: [], progress: [:], today: today
        )
        #expect(item.status == .active)
        #expect(item.title == "Instagram")
        #expect(item.selection?.applicationTokens.count == 1)
        guard case .app(let label, let token) = item.target else { Issue.record("not an app target"); return }
        #expect(label == "Instagram")
        #expect(token != nil)
    }

    @Test func undecodableAppSelectionNeedsReselect() {
        let item = GoalListItem.make(
            goal: goal(id: 2, type: .app, selection: "not-a-selection", label: "Instagram"),
            categories: [], progress: [2: 40], today: today
        )
        #expect(item.status == .needsReselect)
        #expect(item.caption == "Re-select app")
        #expect(item.selection == nil)
        #expect(item.title == "Instagram")
    }

    @Test func emptyAppSelectionNeedsReselect() throws {
        let empty = try #require(SelectionCodec.encode(FamilyActivitySelection()))
        let item = GoalListItem.make(goal: goal(id: 2, type: .app, selection: empty, label: "X"), categories: [], progress: [:], today: today)
        #expect(item.status == .needsReselect)
    }

    @Test func categoryGoalUsesCategoryNameColorAndSelection() throws {
        let cat = category(id: 5, name: "Social", color: "#34C759", selection: try encodedAppSelection())
        let item = GoalListItem.make(goal: goal(id: 3, type: .category, categoryId: 5), categories: [cat], progress: [3: 100], today: today)
        #expect(item.status == .active)
        #expect(item.title == "Social")
        #expect(item.target == .category(name: "Social", colorHex: "#34C759"))
        #expect(item.caption == "Limit reached")
        #expect(item.selection != nil)
    }

    @Test func categoryWithUndecodableSelectionNeedsReselect() {
        let cat = category(id: 5, selection: "%%%")
        let item = GoalListItem.make(goal: goal(id: 3, type: .category, categoryId: 5), categories: [cat], progress: [:], today: today)
        #expect(item.status == .needsReselect)
        #expect(item.caption == "Re-select apps")
    }

    @Test func missingCategoryNeedsReselect() {
        let item = GoalListItem.make(goal: goal(id: 3, type: .category, categoryId: 9), categories: [], progress: [:], today: today)
        #expect(item.status == .needsReselect)
        #expect(item.title == "Unknown category")
    }

    @Test func nonDailyGoalIsNotMonitored() {
        let item = GoalListItem.make(goal: goal(id: 4, frequency: .weekly), categories: [], progress: [:], today: today)
        #expect(item.status == .notMonitored)
        #expect(item.caption == "Not monitored")
        #expect(!item.limitText.contains("week"))
    }

    @Test func temporaryGoalOutsideRangeIsNotActiveToday() {
        let future = GoalListItem.make(goal: goal(id: 6, temporary: true, start: "2026-11-20", end: "2026-11-30"), categories: [], progress: [:], today: today)
        #expect(future.status == .notActiveToday)
        #expect(future.caption == "Not active today")

        let past = GoalListItem.make(goal: goal(id: 6, temporary: true, start: "2026-11-01", end: "2026-11-13"), categories: [], progress: [:], today: today)
        #expect(past.status == .notActiveToday)

        let inside = GoalListItem.make(goal: goal(id: 6, temporary: true, start: "2026-11-14", end: "2026-11-14"), categories: [], progress: [:], today: today)
        #expect(inside.status == .active)
    }
}

// MARK: - GoalsViewModel

@Suite("Goals UI — GoalsViewModel")
@MainActor
struct GoalsViewModelTests {

    private let cal = calendar("UTC")
    private var now: Date { date(2026, 11, 14, 12, in: cal) }

    private func makeVM(
        goals: MockGoalService? = nil,
        categories: MockCategoryService? = nil,
        progress: MockProgressReader? = nil,
        monitoring: MockMonitoring? = nil
    ) -> GoalsViewModel {
        GoalsViewModel(
            goalService: goals ?? MockGoalService(), categoryService: categories ?? MockCategoryService(),
            progressReader: progress ?? MockProgressReader(), monitoring: monitoring ?? MockMonitoring(),
            now: { [now] in now }, calendar: cal
        )
    }

    @Test func loadsItemsSortedById() async {
        let goals = MockGoalService()
        goals.goals = [goal(id: 3), goal(id: 1, type: .app, selection: "bad", label: "X")]
        let vm = makeVM(goals: goals)

        await vm.load(userId: UUID())

        #expect(vm.items.map(\.id) == [1, 3])
        #expect(vm.isLoading == false)
        #expect(vm.error == nil)
    }

    @Test func loadFailureSetsError() async {
        let goals = MockGoalService()
        goals.fetchError = Offline()
        let vm = makeVM(goals: goals)

        await vm.load(userId: UUID())

        #expect(vm.error != nil)
        #expect(vm.items.isEmpty)
        #expect(vm.isLoading == false)
    }

    @Test func categoryLoadFailureSetsError() async {
        let categories = MockCategoryService()
        categories.fetchError = Offline()
        let vm = makeVM(categories: categories)

        await vm.load(userId: UUID())

        #expect(vm.error != nil)
    }

    @Test func undecodableSelectionIsMarked() async {
        let goals = MockGoalService()
        goals.goals = [goal(id: 1, type: .app, selection: "bad", label: "Instagram")]
        let vm = makeVM(goals: goals)

        await vm.load(userId: UUID())

        #expect(vm.items.first?.status == .needsReselect)
    }

    @Test func progressComesFromTheReader() async {
        let goals = MockGoalService()
        goals.goals = [goal(id: 1)]
        let progress = MockProgressReader()
        progress.progress = [1: 30]
        let vm = makeVM(goals: goals, progress: progress)

        await vm.load(userId: UUID())
        #expect(vm.items.first?.percent == 30)

        progress.progress = [1: 80]
        vm.refreshProgress()
        #expect(vm.items.first?.percent == 80)
        #expect(goals.fetchCount == 1, "refreshing progress must not refetch goals")
    }

    @Test func deleteRemovesItemAndRegistersOnce() async {
        let goals = MockGoalService()
        goals.goals = [goal(id: 1), goal(id: 2)]
        let monitoring = MockMonitoring()
        let vm = makeVM(goals: goals, monitoring: monitoring)
        await vm.load(userId: UUID())

        let ok = await vm.deleteGoal(id: 1, userId: UUID())

        #expect(ok)
        #expect(vm.items.map(\.id) == [2])
        #expect(goals.deletedIds == [1])
        #expect(monitoring.calls == 1)
    }

    @Test func failedDeleteKeepsItemAndNeverRegisters() async {
        let goals = MockGoalService()
        goals.goals = [goal(id: 1)]
        goals.deleteError = Offline()
        let monitoring = MockMonitoring()
        let vm = makeVM(goals: goals, monitoring: monitoring)
        await vm.load(userId: UUID())

        let ok = await vm.deleteGoal(id: 1, userId: UUID())

        #expect(!ok)
        #expect(vm.items.map(\.id) == [1])
        #expect(vm.actionError != nil)
        #expect(vm.error == nil, "a failed delete must not replace the list with an error screen")
        #expect(monitoring.calls == 0)
    }

    @Test func reselectRejectsInvalidSelectionWithoutSaving() async {
        let goals = MockGoalService()
        goals.goals = [goal(id: 1, type: .app, selection: "bad", label: "X")]
        let monitoring = MockMonitoring()
        let vm = makeVM(goals: goals, monitoring: monitoring)
        await vm.load(userId: UUID())

        let message = await vm.reselectApp(goalId: 1, selection: FamilyActivitySelection(), userId: UUID())

        #expect(message == "Choose an app.")
        #expect(goals.updatedSelections.isEmpty)
        #expect(monitoring.calls == 0)
    }

    @Test func reselectSavesAndReactivates() async throws {
        let goals = MockGoalService()
        goals.goals = [goal(id: 1, type: .app, selection: "bad", label: "X")]
        let monitoring = MockMonitoring()
        let vm = makeVM(goals: goals, monitoring: monitoring)
        await vm.load(userId: UUID())

        let message = await vm.reselectApp(goalId: 1, selection: try appSelection(seeds: [7]), userId: UUID())

        #expect(message == nil)
        #expect(goals.updatedSelections.map(\.id) == [1])
        let saved = try #require(goals.updatedSelections.first?.selection)
        #expect(SelectionCodec.decode(saved)?.applicationTokens.count == 1)
        #expect(vm.items.first?.status == .active)
        #expect(monitoring.calls == 1)
    }

    @Test func reselectDuplicateMapsMessageAndNeverRegisters() async throws {
        let goals = MockGoalService()
        goals.goals = [goal(id: 1, type: .app, selection: "bad", label: "X")]
        goals.updateError = uniqueViolation
        let monitoring = MockMonitoring()
        let vm = makeVM(goals: goals, monitoring: monitoring)
        await vm.load(userId: UUID())

        let message = await vm.reselectApp(goalId: 1, selection: try appSelection(seeds: [7]), userId: UUID())

        #expect(message == "You already have a daily goal for this.")
        #expect(vm.items.first?.status == .needsReselect)
        #expect(monitoring.calls == 0)
    }
}

// MARK: - AddGoalViewModel

@Suite("Goals UI — AddGoalViewModel")
@MainActor
struct AddGoalViewModelTests {

    private let cal = calendar("UTC")
    private var now: Date { date(2026, 11, 14, 12, in: cal) }

    private func makeVM(
        goals: MockGoalService? = nil,
        categories: MockCategoryService? = nil,
        monitoring: MockMonitoring? = nil
    ) -> AddGoalViewModel {
        AddGoalViewModel(
            goalService: goals ?? MockGoalService(), categoryService: categories ?? MockCategoryService(),
            monitoring: monitoring ?? MockMonitoring(), now: { [now] in now }, calendar: cal
        )
    }

    @Test func defaultsToAppWithOneHourAndNoSelection() {
        let vm = makeVM()
        #expect(vm.targetType == .app)
        #expect(vm.hours == 1 && vm.minutes == 0)
        #expect(vm.isTemporary == false)
        #expect(vm.validationError == "Choose an app.")
        #expect(!vm.canSave)
    }

    @Test func totalGoalSavesAndRegistersOnce() async throws {
        let goals = MockGoalService()
        let monitoring = MockMonitoring()
        let vm = makeVM(goals: goals, monitoring: monitoring)
        vm.targetType = .total
        vm.hours = 2; vm.minutes = 15

        let ok = await vm.save(userId: UUID())

        #expect(ok)
        let insert = try #require(goals.created.first)
        #expect(insert.targetType == .total)
        #expect(insert.frequency == .daily)
        #expect(insert.limitSeconds == 8100)
        #expect(insert.selection == nil)
        #expect(insert.label == nil)
        #expect(insert.categoryId == nil)
        #expect(insert.temporary == false)
        #expect(insert.startDate == nil && insert.endDate == nil)
        #expect(monitoring.calls == 1)
        #expect(vm.isSaving == false)
    }

    @Test func appGoalEncodesSelectionAndTrimsLabel() async throws {
        let goals = MockGoalService()
        let vm = makeVM(goals: goals)
        vm.appSelection = try appSelection(seeds: [3])
        vm.label = "  Instagram  "
        #expect(vm.canSave)

        let ok = await vm.save(userId: UUID())

        #expect(ok)
        let insert = try #require(goals.created.first)
        #expect(insert.targetType == .app)
        #expect(insert.label == "Instagram")
        #expect(insert.categoryId == nil)
        let encoded = try #require(insert.selection)
        #expect(SelectionCodec.decode(encoded)?.applicationTokens.count == 1)
    }

    @Test func appGoalRequiresLabel() throws {
        let vm = makeVM()
        vm.appSelection = try appSelection(seeds: [3])
        vm.label = "   "
        #expect(vm.validationError == "Enter a name for this app.")
        #expect(!vm.canSave)
    }

    @Test func appGoalRejectsTwoApps() throws {
        let vm = makeVM()
        vm.appSelection = try appSelection(seeds: [3, 4])
        vm.label = "Social"
        #expect(vm.validationError == "Choose only one app.")
    }

    @Test func categoryGoalRequiresACategory() async {
        let goals = MockGoalService()
        let vm = makeVM(goals: goals)
        vm.targetType = .category
        #expect(vm.validationError == "Choose a category.")

        let ok = await vm.save(userId: UUID())
        #expect(!ok)
        #expect(goals.created.isEmpty)
    }

    @Test func categoryGoalSavesCategoryId() async throws {
        let goals = MockGoalService()
        let vm = makeVM(goals: goals)
        vm.targetType = .category
        vm.selectedCategoryId = 5

        #expect(await vm.save(userId: UUID()))
        let insert = try #require(goals.created.first)
        #expect(insert.targetType == .category)
        #expect(insert.categoryId == 5)
        #expect(insert.selection == nil)
        #expect(insert.label == nil)
    }

    @Test func limitBelowMinimumBlocksSave() {
        let vm = makeVM()
        vm.targetType = .total
        vm.hours = 0; vm.minutes = 4
        #expect(vm.validationError == "Limit must be at least 5 minutes.")
        #expect(!vm.canSave)
    }

    @Test func temporaryGoalCarriesDayStrings() async throws {
        let goals = MockGoalService()
        let vm = makeVM(goals: goals)
        vm.targetType = .total
        vm.isTemporary = true
        vm.startDate = date(2026, 11, 15, in: cal)
        vm.endDate = date(2026, 11, 22, in: cal)

        #expect(await vm.save(userId: UUID()))
        let insert = try #require(goals.created.first)
        #expect(insert.temporary)
        #expect(insert.startDate == "2026-11-15")
        #expect(insert.endDate == "2026-11-22")
    }

    @Test func temporaryRangeIsValidated() {
        let vm = makeVM()
        vm.targetType = .total
        vm.isTemporary = true
        vm.startDate = date(2026, 11, 20, in: cal)
        vm.endDate = date(2026, 11, 19, in: cal)
        #expect(vm.validationError == "End date must be on or after the start date.")
    }

    @Test func failedCreateNeverRegisters() async {
        let goals = MockGoalService()
        goals.createError = Offline()
        let monitoring = MockMonitoring()
        let vm = makeVM(goals: goals, monitoring: monitoring)
        vm.targetType = .total

        let ok = await vm.save(userId: UUID())

        #expect(!ok)
        #expect(vm.errorMessage == "Couldn't save the goal. Please try again.")
        #expect(monitoring.calls == 0)
        #expect(vm.isSaving == false)
    }

    @Test func duplicateGoalMapsFriendlyMessage() async {
        let goals = MockGoalService()
        goals.createError = uniqueViolation
        let monitoring = MockMonitoring()
        let vm = makeVM(goals: goals, monitoring: monitoring)
        vm.targetType = .total

        #expect(!(await vm.save(userId: UUID())))
        #expect(vm.errorMessage == "You already have a daily goal for this.")
        #expect(monitoring.calls == 0)
    }

    @Test func loadsCategoriesSortedByName() async {
        let categories = MockCategoryService()
        categories.categories = [category(id: 1, name: "Work"), category(id: 2, name: "games")]
        let vm = makeVM(categories: categories)

        await vm.loadCategories(userId: UUID())

        #expect(vm.categories.map(\.name) == ["games", "Work"])
        #expect(vm.categoriesError == nil)
    }

    @Test func categoryLoadFailureIsReported() async {
        let categories = MockCategoryService()
        categories.fetchError = Offline()
        let vm = makeVM(categories: categories)

        await vm.loadCategories(userId: UUID())

        #expect(vm.categoriesError != nil)
    }

    @Test func newCategoryIsAddedAndSelected() {
        let vm = makeVM()
        vm.targetType = .category
        vm.categoryCreated(category(id: 42, name: "Reading"))
        #expect(vm.categories.map(\.id) == [42])
        #expect(vm.selectedCategoryId == 42)
        #expect(vm.validationError == nil)
    }
}

// MARK: - CategoryEditorViewModel

@Suite("Goals UI — CategoryEditorViewModel")
@MainActor
struct CategoryEditorViewModelTests {

    private func makeVM(
        _ mode: CategoryEditorViewModel.Mode = .create,
        service: MockCategoryService? = nil,
        monitoring: MockMonitoring? = nil
    ) -> CategoryEditorViewModel {
        CategoryEditorViewModel(mode: mode, categoryService: service ?? MockCategoryService(), monitoring: monitoring ?? MockMonitoring())
    }

    @Test func createDefaults() {
        let vm = makeVM()
        #expect(vm.name.isEmpty)
        #expect(vm.color == CategoryPalette.defaultColor)
        #expect(vm.validationError == "Enter a name.")
        #expect(!vm.canSave)
    }

    @Test func emptySelectionBlocksSave() async {
        let service = MockCategoryService()
        let vm = makeVM(service: service)
        vm.name = "Social"
        #expect(vm.validationError == "Choose at least one app or category.")

        let saved = await vm.save(userId: UUID())

        #expect(saved == nil)
        #expect(service.created.isEmpty)
    }

    @Test func createSavesTrimmedNameAndRegistersOnce() async throws {
        let service = MockCategoryService()
        let monitoring = MockMonitoring()
        let vm = makeVM(service: service, monitoring: monitoring)
        vm.name = "  Social  "
        vm.color = CategoryPalette.colors[2]
        vm.selection = try appSelection(seeds: [1, 2])

        let saved = await vm.save(userId: UUID())

        #expect(saved?.name == "Social")
        let call = try #require(service.created.first)
        #expect(call.name == "Social")
        #expect(call.color == CategoryPalette.colors[2])
        #expect(SelectionCodec.decode(call.selection)?.applicationTokens.count == 2)
        #expect(monitoring.calls == 1)
        #expect(vm.isSaving == false)
    }

    @Test func duplicateNameMapsMessageAndNeverRegisters() async throws {
        let service = MockCategoryService()
        service.saveError = uniqueViolation
        let monitoring = MockMonitoring()
        let vm = makeVM(service: service, monitoring: monitoring)
        vm.name = "Social"
        vm.selection = try appSelection(seeds: [1])

        let saved = await vm.save(userId: UUID())

        #expect(saved == nil)
        #expect(vm.errorMessage == "You already have a category with this name.")
        #expect(monitoring.calls == 0)
    }

    @Test func invalidColorBlocksSave() throws {
        let vm = makeVM()
        vm.name = "Social"
        vm.selection = try appSelection(seeds: [1])
        vm.color = "red"
        #expect(vm.validationError == "Choose a color.")
    }

    @Test func editPrefillsFromCategory() throws {
        let encoded = try encodedAppSelection(seed: 9)
        let vm = makeVM(.edit(category(id: 7, name: "Games", color: "#AF52DE", selection: encoded)))
        #expect(vm.name == "Games")
        #expect(vm.color == "#AF52DE")
        #expect(vm.selection.applicationTokens.count == 1)
        #expect(vm.selectionNeedsReselect == false)
        #expect(vm.canSave)
    }

    @Test func editWithUndecodableSelectionAsksToReselect() {
        let vm = makeVM(.edit(category(id: 7, selection: "%%%")))
        #expect(vm.selectionNeedsReselect)
        #expect(SelectionCodec.isEmpty(vm.selection))
        #expect(!vm.canSave)
    }

    @Test func editUpdatesAndRegistersOnce() async throws {
        let service = MockCategoryService()
        let monitoring = MockMonitoring()
        let vm = makeVM(.edit(category(id: 7, name: "Games", selection: try encodedAppSelection())), service: service, monitoring: monitoring)
        vm.name = "Gaming"

        let saved = await vm.save(userId: UUID())

        #expect(saved?.id == 7)
        #expect(service.updated.map(\.id) == [7])
        #expect(service.updated.first?.name == "Gaming")
        #expect(service.created.isEmpty)
        #expect(monitoring.calls == 1)
    }

    @Test func failedEditNeverRegisters() async throws {
        let service = MockCategoryService()
        service.saveError = Offline()
        let monitoring = MockMonitoring()
        let vm = makeVM(.edit(category(id: 7, selection: try encodedAppSelection())), service: service, monitoring: monitoring)

        #expect(await vm.save(userId: UUID()) == nil)
        #expect(vm.errorMessage == "Couldn't save the category. Please try again.")
        #expect(monitoring.calls == 0)
    }
}

// MARK: - CategoriesViewModel

@Suite("Goals UI — CategoriesViewModel")
@MainActor
struct CategoriesViewModelTests {

    @Test func loadsSortedByName() async {
        let service = MockCategoryService()
        service.categories = [category(id: 1, name: "Work"), category(id: 2, name: "Games")]
        let vm = CategoriesViewModel(categoryService: service, monitoring: MockMonitoring())

        await vm.load(userId: UUID())

        #expect(vm.categories.map(\.name) == ["Games", "Work"])
        #expect(vm.isLoading == false)
        #expect(vm.error == nil)
    }

    @Test func loadFailureSetsError() async {
        let service = MockCategoryService()
        service.fetchError = Offline()
        let vm = CategoriesViewModel(categoryService: service, monitoring: MockMonitoring())

        await vm.load(userId: UUID())

        #expect(vm.error != nil)
        #expect(vm.categories.isEmpty)
    }

    @Test func deleteRemovesAndRegistersOnce() async {
        let service = MockCategoryService()
        service.categories = [category(id: 1, name: "A"), category(id: 2, name: "B")]
        let monitoring = MockMonitoring()
        let vm = CategoriesViewModel(categoryService: service, monitoring: monitoring)
        await vm.load(userId: UUID())

        let ok = await vm.delete(id: 1, userId: UUID())

        #expect(ok)
        #expect(vm.categories.map(\.id) == [2])
        #expect(service.deletedIds == [1])
        #expect(monitoring.calls == 1)
    }

    @Test func failedDeleteKeepsCategoryAndNeverRegisters() async {
        let service = MockCategoryService()
        service.categories = [category(id: 1)]
        service.deleteError = Offline()
        let monitoring = MockMonitoring()
        let vm = CategoriesViewModel(categoryService: service, monitoring: monitoring)
        await vm.load(userId: UUID())

        let ok = await vm.delete(id: 1, userId: UUID())

        #expect(!ok)
        #expect(vm.categories.map(\.id) == [1])
        #expect(vm.actionError != nil)
        #expect(monitoring.calls == 0)
    }

    @Test func savedCategoryReplacesOrAppends() async {
        let service = MockCategoryService()
        service.categories = [category(id: 1, name: "B")]
        let vm = CategoriesViewModel(categoryService: service, monitoring: MockMonitoring())
        await vm.load(userId: UUID())

        vm.categorySaved(category(id: 1, name: "C"))
        vm.categorySaved(category(id: 2, name: "A"))

        #expect(vm.categories.map(\.name) == ["A", "C"])
    }
}

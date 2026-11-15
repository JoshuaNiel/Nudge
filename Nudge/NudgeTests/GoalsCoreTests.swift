import Testing
import Foundation
import DeviceActivity
import FamilyControls
@testable import Nudge

// Phase 3a — Goals core (tokens + milestones). See docs/specs/phase-3-goals.md.

// MARK: - Helpers

private func utcDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
}

private func fixedCalendar(_ tz: String) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: tz)!
    return cal
}

private func summary(
    id: Int,
    type: GoalTargetType = .total,
    limit: Int = 3600,
    label: String = "All Apps",
    frequency: GoalFrequency = .daily,
    start: String? = nil,
    end: String? = nil,
    selection: Data? = nil
) -> GoalSummary {
    GoalSummary(
        goalId: id,
        eventName: MonitoringPlan.goalEventBase(goalId: id),
        limitSeconds: limit,
        targetLabel: label,
        targetType: type,
        frequency: frequency,
        startDate: start,
        endDate: end,
        selectionData: selection
    )
}

private func freshDefaults(_ name: String) -> UserDefaults {
    let suite = "test.goalscore.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

// MARK: - Goal / AppCategory / GoalInsert coding

@Suite("Goals core — model coding")
@MainActor
struct GoalsCoreModelCodingTests {

    @Test func goalDecodesSelectionAndLabel() throws {
        let json = """
        {
            "id": 7, "user_id": "\(UUID().uuidString)", "limit_seconds": 1800,
            "frequency": "daily", "target_type": "app", "bundle_id": null,
            "category_id": null, "temporary": false, "start_date": null, "end_date": null,
            "selection": "YnBsaXN0", "label": "Instagram"
        }
        """.data(using: .utf8)!
        let goal = try JSONDecoder().decode(Goal.self, from: json)
        #expect(goal.selection == "YnBsaXN0")
        #expect(goal.label == "Instagram")
    }

    /// Rows read before migration 006 runs have no selection/label columns.
    @Test func goalDecodesWithoutNewColumns() throws {
        let json = """
        {
            "id": 7, "user_id": "\(UUID().uuidString)", "limit_seconds": 1800,
            "frequency": "daily", "target_type": "total", "bundle_id": null,
            "category_id": null, "temporary": false, "start_date": null, "end_date": null
        }
        """.data(using: .utf8)!
        let goal = try JSONDecoder().decode(Goal.self, from: json)
        #expect(goal.selection == nil)
        #expect(goal.label == nil)
    }

    @Test func appCategoryDecodesSelection() throws {
        let json = """
        { "id": 3, "user_id": "\(UUID().uuidString)", "name": "Social", "color": "#FF5733", "selection": "abc=" }
        """.data(using: .utf8)!
        let category = try JSONDecoder().decode(AppCategory.self, from: json)
        #expect(category.selection == "abc=")
    }

    @Test func appCategoryDecodesWithoutSelection() throws {
        let json = """
        { "id": 3, "user_id": "\(UUID().uuidString)", "name": "Social", "color": "#FF5733" }
        """.data(using: .utf8)!
        let category = try JSONDecoder().decode(AppCategory.self, from: json)
        #expect(category.selection == nil)
    }

    @Test func goalInsertEncodesSelectionAndLabelSnakeCase() throws {
        let insert = GoalInsert(
            userId: UUID(), limitSeconds: 1800, frequency: .daily, targetType: .app,
            categoryId: nil, selection: "abc=", label: "Instagram",
            temporary: false, startDate: nil, endDate: nil
        )
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(insert)) as! [String: Any]
        #expect(json["selection"] as? String == "abc=")
        #expect(json["label"] as? String == "Instagram")
        #expect(json["target_type"] as? String == "app")
        #expect(json["bundle_id"] == nil, "bundle_id is deprecated and must not be written")
    }
}

// MARK: - GoalSummary coding (App Group JSON)

@Suite("Goals core — GoalSummary coding")
@MainActor
struct GoalSummaryCodingTests {

    @Test func roundTripsNewFields() throws {
        let original = summary(
            id: 42, type: .category, limit: 5400, label: "Social",
            frequency: .daily, start: "2026-11-01", end: "2026-11-30",
            selection: Data([1, 2, 3])
        )
        let decoded = try JSONDecoder().decode(GoalSummary.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func encodesSnakeCaseKeys() throws {
        let data = try JSONEncoder().encode(summary(id: 1, start: "2026-11-01", end: "2026-11-02", selection: Data([9])))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["goal_id", "event_name", "limit_seconds", "target_label", "target_type",
                    "frequency", "start_date", "end_date", "selection_data"] {
            #expect(json[key] != nil, "\(key) missing")
        }
        #expect(json["targetType"] == nil)
    }

    /// App Group JSON written by the previous version (no target_type/frequency/dates/selection)
    /// must still decode, or the extension's midnight re-arm would find no goals after an upgrade.
    @Test func decodesLegacyTotalSummary() throws {
        let json = """
        [{"goal_id": 5, "event_name": "total", "limit_seconds": 7200,
          "target_label": "All Apps", "app_bundle_id": null}]
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([GoalSummary].self, from: json)
        #expect(decoded.count == 1)
        #expect(decoded[0].targetType == .total)
        #expect(decoded[0].frequency == .daily)
        #expect(decoded[0].startDate == nil)
        #expect(decoded[0].endDate == nil)
        #expect(decoded[0].selectionData == nil)
        #expect(!decoded[0].isSessionTimeout)
    }

    @Test func decodesLegacySessionAppAndCategorySummaries() throws {
        let json = """
        [{"goal_id": 0, "event_name": "session.timeout", "limit_seconds": 2700, "target_label": "Session"},
         {"goal_id": 2, "event_name": "app.com.instagram.Instagram", "limit_seconds": 1800,
          "target_label": "Instagram", "app_bundle_id": "com.instagram.Instagram"},
         {"goal_id": 3, "event_name": "category.4", "limit_seconds": 3600, "target_label": "Social"}]
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([GoalSummary].self, from: json)
        #expect(decoded[0].isSessionTimeout)
        #expect(decoded[1].targetType == .app)
        #expect(decoded[2].targetType == .category)
    }

    @Test func loadSummariesReadsLegacyAppGroupJSON() throws {
        let defaults = freshDefaults(#function)
        let json = """
        [{"goal_id": 5, "event_name": "total", "limit_seconds": 7200, "target_label": "All Apps", "app_bundle_id": null}]
        """.data(using: .utf8)!
        defaults.set(json, forKey: AppGroupKeys.goalsActive)
        #expect(MonitoringPlan.loadSummaries(from: defaults).map(\.goalId) == [5])
    }
}

// MARK: - SelectionCodec

@Suite("Goals core — SelectionCodec")
@MainActor
struct SelectionCodecTests {

    @Test func emptySelectionRoundTrips() throws {
        let encoded = try #require(SelectionCodec.encode(FamilyActivitySelection()))
        #expect(!encoded.isEmpty)
        #expect(Data(base64Encoded: encoded) != nil, "must be base64")
        let decoded = try #require(SelectionCodec.decode(encoded))
        #expect(decoded.applicationTokens.isEmpty)
        #expect(decoded.categoryTokens.isEmpty)
        #expect(decoded.webDomainTokens.isEmpty)
        #expect(SelectionCodec.isEmpty(decoded))
    }

    @Test func dataRoundTrips() throws {
        let encoded = try #require(SelectionCodec.encode(FamilyActivitySelection()))
        let data = try #require(SelectionCodec.data(fromBase64: encoded))
        #expect(SelectionCodec.decode(data: data) != nil)
    }

    @Test func garbageBase64ReturnsNil() {
        #expect(SelectionCodec.decode("not base64 !!!") == nil)
        #expect(SelectionCodec.data(fromBase64: "not base64 !!!") == nil)
    }

    @Test func validBase64OfGarbageReturnsNil() {
        let garbage = Data("hello world".utf8).base64EncodedString()
        #expect(SelectionCodec.decode(garbage) == nil)
        #expect(SelectionCodec.decode(data: Data([0xFF, 0x00, 0x13])) == nil)
    }

    @Test func emptyStringReturnsNil() {
        #expect(SelectionCodec.decode("") == nil)
    }
}

// MARK: - Milestone names and thresholds

@Suite("Goals core — milestone events")
@MainActor
struct MilestoneEventTests {

    @Test func stepIsTenPercent() {
        #expect(MonitoringPlan.milestoneStepPercent == 10)
        #expect(MonitoringPlan.milestonePercents == [10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
    }

    @Test func eventNameFormatHasNoPadding() {
        #expect(MonitoringPlan.milestoneEventName(goalId: 42, percent: 50) == "goal.42.p50")
        #expect(MonitoringPlan.milestoneEventName(goalId: 42, percent: 100) == "goal.42.p100")
        #expect(MonitoringPlan.goalEventBase(goalId: 42) == "goal.42")
    }

    @Test func thresholdsAreProportional() {
        #expect(MonitoringPlan.milestoneThresholdSeconds(limitSeconds: 3600, percent: 10) == 360)
        #expect(MonitoringPlan.milestoneThresholdSeconds(limitSeconds: 3600, percent: 50) == 1800)
        #expect(MonitoringPlan.milestoneThresholdSeconds(limitSeconds: 3600, percent: 100) == 3600)
    }

    @Test func minimumUiLimitDividesExactly() {
        // 5 min is the smallest limit the Add Goal sheet allows.
        let thresholds = MonitoringPlan.milestonePercents.map {
            MonitoringPlan.milestoneThresholdSeconds(limitSeconds: 300, percent: $0)
        }
        #expect(thresholds == [30, 60, 90, 120, 150, 180, 210, 240, 270, 300])
    }

    /// Non-divisible limits floor, so pNN never fires *after* NN% — and p100 is exact.
    @Test func thresholdsFloorAndP100IsExact() {
        #expect(MonitoringPlan.milestoneThresholdSeconds(limitSeconds: 125, percent: 10) == 12)
        #expect(MonitoringPlan.milestoneThresholdSeconds(limitSeconds: 125, percent: 100) == 125)
    }

    @Test func thresholdIsAtLeastOneSecond() {
        #expect(MonitoringPlan.milestoneThresholdSeconds(limitSeconds: 5, percent: 10) == 1)
        #expect(MonitoringPlan.milestoneThresholdSeconds(limitSeconds: 1, percent: 10) == 1)
    }

    @Test func specsForAGoalAreTenMilestones() {
        let specs = MonitoringPlan.eventSpecs(for: summary(id: 9, limit: 1200))
        #expect(specs.count == 10)
        #expect(specs.first == .init(name: "goal.9.p10", thresholdSeconds: 120))
        #expect(specs.last == .init(name: "goal.9.p100", thresholdSeconds: 1200))
    }

    @Test func specForSessionTimeoutIsSingleUnchangedEvent() {
        let specs = MonitoringPlan.eventSpecs(for: MonitoringPlan.sessionTimeoutSummary(minutes: 45))
        #expect(specs == [.init(name: "session.timeout", thresholdSeconds: 2700)])
    }
}

// MARK: - Event name parsing

@Suite("Goals core — event name parsing")
@MainActor
struct EventNameParsingTests {

    @Test func parsesValidMilestones() {
        #expect(MonitoringPlan.parseEventName("goal.42.p10") == .milestone(goalId: 42, percent: 10))
        #expect(MonitoringPlan.parseEventName("goal.42.p100") == .milestone(goalId: 42, percent: 100))
        #expect(MonitoringPlan.parseEventName("goal.1.p50") == .milestone(goalId: 1, percent: 50))
    }

    @Test func parsesSessionTimeout() {
        #expect(MonitoringPlan.parseEventName("session.timeout") == .sessionTimeout)
    }

    @Test func rejectsOutOfRangePercents() {
        #expect(MonitoringPlan.parseEventName("goal.42.p0") == .unknown)
        #expect(MonitoringPlan.parseEventName("goal.42.p110") == .unknown)
        #expect(MonitoringPlan.parseEventName("goal.42.p15") == .unknown, "not a registered step")
    }

    @Test func rejectsNonCanonicalForms() {
        #expect(MonitoringPlan.parseEventName("goal.42.p010") == .unknown)
        #expect(MonitoringPlan.parseEventName("goal.+42.p10") == .unknown)
        #expect(MonitoringPlan.parseEventName("goal.-1.p10") == .unknown)
        #expect(MonitoringPlan.parseEventName("goal.0.p10") == .unknown)
        #expect(MonitoringPlan.parseEventName("goal.42.p10.extra") == .unknown)
    }

    @Test func rejectsJunkAndLegacyNames() {
        for name in ["", "goal", "goal.", "goal.42", "goal.42.", "goal.abc.p10", "goal.42.x10",
                     "total", "app.com.instagram.Instagram", "category.4", "session.timeout2"] {
            #expect(MonitoringPlan.parseEventName(name) == .unknown, "\(name)")
        }
    }

    @Test func roundTripsEveryRegisteredName() {
        for p in MonitoringPlan.milestonePercents {
            let name = MonitoringPlan.milestoneEventName(goalId: 123, percent: p)
            #expect(MonitoringPlan.parseEventName(name) == .milestone(goalId: 123, percent: p))
        }
    }
}

// MARK: - Composition (frequency + temporary date filter)

@Suite("Goals core — composeSummaries filter")
@MainActor
struct ComposeFilterTests {

    private let utc = fixedCalendar("UTC")

    @Test func keepsDailyDropsWeeklyAndMonthly() {
        let composed = MonitoringPlan.composeSummaries(
            goals: [summary(id: 1), summary(id: 2, frequency: .weekly), summary(id: 3, frequency: .monthly)],
            sessionTimeoutMinutes: nil, today: utcDate(2026, 11, 14), calendar: utc
        )
        #expect(composed.map(\.goalId) == [1])
    }

    @Test func temporaryGoalInsideRangeIsKept() {
        let composed = MonitoringPlan.composeSummaries(
            goals: [summary(id: 1, start: "2026-11-10", end: "2026-11-20")],
            sessionTimeoutMinutes: nil, today: utcDate(2026, 11, 14), calendar: utc
        )
        #expect(composed.map(\.goalId) == [1])
    }

    @Test func temporaryRangeIsInclusiveOnBothEnds() {
        let goals = [summary(id: 1, start: "2026-11-14", end: "2026-11-20"),
                     summary(id: 2, start: "2026-11-10", end: "2026-11-14")]
        let composed = MonitoringPlan.composeSummaries(
            goals: goals, sessionTimeoutMinutes: nil, today: utcDate(2026, 11, 14), calendar: utc
        )
        #expect(composed.map(\.goalId).sorted() == [1, 2])
    }

    @Test func temporaryGoalOutsideRangeIsDropped() {
        let goals = [summary(id: 1, start: "2026-11-15", end: "2026-11-20"),   // not started
                     summary(id: 2, start: "2026-11-01", end: "2026-11-13")]   // expired
        let composed = MonitoringPlan.composeSummaries(
            goals: goals, sessionTimeoutMinutes: nil, today: utcDate(2026, 11, 14), calendar: utc
        )
        #expect(composed.isEmpty)
    }

    @Test func singleDayRange() {
        let goals = [summary(id: 1, start: "2026-11-14", end: "2026-11-14")]
        #expect(MonitoringPlan.composeSummaries(goals: goals, sessionTimeoutMinutes: nil,
                                                today: utcDate(2026, 11, 14), calendar: utc).count == 1)
        #expect(MonitoringPlan.composeSummaries(goals: goals, sessionTimeoutMinutes: nil,
                                                today: utcDate(2026, 11, 15), calendar: utc).isEmpty)
    }

    /// The date filter must use the *local* day: 05:30 UTC on Nov 15 is still Nov 14 in Denver.
    @Test func usesCalendarTimeZoneForToday() {
        let goals = [summary(id: 1, start: "2026-11-10", end: "2026-11-14")]
        let instant = utcDate(2026, 11, 15, 5, 30)
        #expect(MonitoringPlan.composeSummaries(goals: goals, sessionTimeoutMinutes: nil,
                                                today: instant, calendar: fixedCalendar("America/Denver")).count == 1)
        #expect(MonitoringPlan.composeSummaries(goals: goals, sessionTimeoutMinutes: nil,
                                                today: instant, calendar: utc).isEmpty)
    }

    @Test func sessionTimeoutStillAppended() {
        let composed = MonitoringPlan.composeSummaries(
            goals: [summary(id: 1, frequency: .weekly)], sessionTimeoutMinutes: 30,
            today: utcDate(2026, 11, 14), calendar: utc
        )
        #expect(composed.map(\.eventName) == ["session.timeout"])
        #expect(composed.first?.limitSeconds == 1800)
    }

    @Test func catalogKeepsEverythingForTheExtension() {
        let catalog = MonitoringPlan.catalog(
            goals: [summary(id: 1, frequency: .weekly), summary(id: 2, start: "2027-01-01", end: "2027-01-02")],
            sessionTimeoutMinutes: 30
        )
        #expect(catalog.count == 3, "future/inactive goals must survive so the midnight re-arm can pick them up")
    }
}

// MARK: - Events built from summaries

@Suite("Goals core — DeviceActivity events")
@MainActor
struct GoalEventsTests {

    @Test func totalGoalRegistersTenMilestonesWithoutFilter() {
        let events = MonitoringPlan.events(for: [summary(id: 4, limit: 3600)])
        #expect(events.count == 10)
        let p50 = events[DeviceActivityEvent.Name("goal.4.p50")]
        #expect(p50?.applications.isEmpty == true)
        #expect(p50?.categories.isEmpty == true)
        #expect(p50?.threshold == DateComponents(hour: 0, minute: 30, second: 0))
        #expect(events[DeviceActivityEvent.Name("goal.4.p100")]?.threshold == DateComponents(hour: 1, minute: 0, second: 0))
    }

    @Test func sessionTimeoutUnchanged() {
        let events = MonitoringPlan.events(for: [MonitoringPlan.sessionTimeoutSummary(minutes: 45)])
        #expect(events.count == 1)
        #expect(events[DeviceActivityEvent.Name("session.timeout")]?.threshold
                == DateComponents(hour: 0, minute: 45, second: 0))
    }

    @Test func appGoalWithoutSelectionIsSkipped() {
        #expect(MonitoringPlan.events(for: [summary(id: 1, type: .app, label: "Instagram")]).isEmpty)
    }

    @Test func goalWithUndecodableSelectionIsSkipped() {
        let events = MonitoringPlan.events(for: [
            summary(id: 1, type: .app, selection: Data("junk".utf8)),
            summary(id: 2, type: .category, selection: Data([0x00, 0x01])),
            summary(id: 3)
        ])
        #expect(Set(events.keys.map(\.rawValue)) == Set(MonitoringPlan.milestonePercents.map { "goal.3.p\($0)" }))
    }

    /// An empty token set would make DeviceActivityEvent monitor *all* usage — never
    /// let an app/category goal silently become a total goal.
    @Test func goalWithEmptySelectionIsSkipped() throws {
        let encoded = try #require(SelectionCodec.encode(FamilyActivitySelection()))
        let data = try #require(SelectionCodec.data(fromBase64: encoded))
        #expect(MonitoringPlan.events(for: [summary(id: 1, type: .category, selection: data)]).isEmpty)
    }

    @Test func eventCountWarningThresholdIsDocumented() {
        #expect(MonitoringPlan.eventCountWarningThreshold == 200)
    }
}

// MARK: - Signature

@Suite("Goals core — signature")
@MainActor
struct GoalSignatureTests {

    @Test func changesWhenSelectionChangesWithSameLimit() {
        let a = MonitoringPlan.signature(for: [summary(id: 1, type: .category, selection: Data([1, 2]))])
        let b = MonitoringPlan.signature(for: [summary(id: 1, type: .category, selection: Data([1, 2, 3]))])
        #expect(a != b)
    }

    @Test func changesWhenSelectionAddedOrRemoved() {
        let a = MonitoringPlan.signature(for: [summary(id: 1, type: .app, selection: nil)])
        let b = MonitoringPlan.signature(for: [summary(id: 1, type: .app, selection: Data([1]))])
        #expect(a != b)
    }

    @Test func isOrderIndependentWithSelections() {
        let x = summary(id: 1, type: .app, selection: Data([1]))
        let y = summary(id: 2, type: .category, selection: Data([2]))
        let z = MonitoringPlan.sessionTimeoutSummary(minutes: 30)
        #expect(MonitoringPlan.signature(for: [x, y, z]) == MonitoringPlan.signature(for: [z, y, x]))
    }

    @Test func stableForIdenticalInput() {
        let s = [summary(id: 1, type: .app, selection: Data([1, 2, 3]))]
        #expect(MonitoringPlan.signature(for: s) == MonitoringPlan.signature(for: s))
    }

    @Test func changesWhenLimitChanges() {
        #expect(MonitoringPlan.signature(for: [summary(id: 1, limit: 60)])
                != MonitoringPlan.signature(for: [summary(id: 1, limit: 120)]))
    }

    @Test func changesWhenTargetTypeChanges() {
        #expect(MonitoringPlan.signature(for: [summary(id: 1, type: .total)])
                != MonitoringPlan.signature(for: [summary(id: 1, type: .app)]))
    }

    @Test func fingerprintIsSha256Hex() {
        let fp = MonitoringPlan.selectionFingerprint(Data("abc".utf8))
        #expect(fp == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(MonitoringPlan.selectionFingerprint(nil) == "-")
    }
}

// MARK: - Registration persists the full catalog

@Suite("Goals core — register")
@MainActor
struct GoalRegisterTests {

    @Test func persistsCatalogButRegistersOnlyTodaysGoals() throws {
        let defaults = freshDefaults(#function)
        let catalog = [summary(id: 1), summary(id: 2, start: "2026-11-20", end: "2026-11-21"),
                       MonitoringPlan.sessionTimeoutSummary(minutes: 30)]
        var registered: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]

        let count = try MonitoringPlan.register(
            catalog: catalog, defaults: defaults,
            now: utcDate(2026, 11, 14), calendar: fixedCalendar("UTC")
        ) { _, events in registered = events }

        #expect(count == 11)
        #expect(registered.count == 11)
        #expect(registered[DeviceActivityEvent.Name("goal.2.p10")] == nil)
        #expect(MonitoringPlan.loadSummaries(from: defaults).count == 3)
    }

    /// A temporary goal starting tomorrow must be armed by the extension at midnight
    /// with the app never opened.
    @Test func extensionPicksUpGoalThatStartsTomorrow() throws {
        let defaults = freshDefaults(#function)
        let cal = fixedCalendar("UTC")
        let catalog = [summary(id: 1), summary(id: 2, start: "2026-11-15", end: "2026-11-16")]
        _ = try MonitoringPlan.register(catalog: catalog, defaults: defaults,
                                        now: utcDate(2026, 11, 14), calendar: cal) { _, _ in }

        let tomorrow = MonitoringPlan.activeSummaries(
            in: MonitoringPlan.loadSummaries(from: defaults), now: utcDate(2026, 11, 15, 0, 1), calendar: cal
        )
        #expect(tomorrow.map(\.goalId).sorted() == [1, 2])
    }

    @Test func persistCatalogWritesWithoutRegistering() {
        let defaults = freshDefaults(#function)
        MonitoringPlan.persistCatalog([summary(id: 8)], defaults: defaults)
        #expect(MonitoringPlan.loadSummaries(from: defaults).map(\.goalId) == [8])
        #expect(defaults.string(forKey: AppGroupKeys.lastRegisteredDay) == nil)
    }
}

// MARK: - Progress + dedup store

@Suite("Goals core — GoalProgressStore")
@MainActor
struct GoalProgressStoreTests {

    @Test func keysAreDayScoped() {
        #expect(AppGroupKeys.progressKey(day: "2026-11-14") == "nudge.progress.2026-11-14")
        #expect(AppGroupKeys.firedKey(day: "2026-11-14") == "nudge.fired.2026-11-14")
    }

    @Test func mergeKeepsMaximum() {
        var p: [Int: Int] = [:]
        p = GoalProgressStore.merged(p, goalId: 1, percent: 30)
        p = GoalProgressStore.merged(p, goalId: 1, percent: 20)
        p = GoalProgressStore.merged(p, goalId: 2, percent: 10)
        #expect(p == [1: 30, 2: 10])
        p = GoalProgressStore.merged(p, goalId: 1, percent: 100)
        #expect(p[1] == 100)
    }

    @Test func recordAndReadProgress() {
        let store = GoalProgressStore(defaults: freshDefaults(#function))
        store.recordProgress(goalId: 4, percent: 50, day: "2026-11-14")
        store.recordProgress(goalId: 4, percent: 40, day: "2026-11-14")   // re-registration re-fires a lower step
        store.recordProgress(goalId: 5, percent: 10, day: "2026-11-14")
        store.recordProgress(goalId: 4, percent: 90, day: "2026-11-13")
        #expect(store.progress(onDay: "2026-11-14") == [4: 50, 5: 10])
        #expect(store.progress(onDay: "2026-11-13") == [4: 90])
        #expect(store.progress(onDay: "2026-11-12").isEmpty)
    }

    @Test func progressForNowUsesLocalDay() {
        let store = GoalProgressStore(defaults: freshDefaults(#function))
        store.recordProgress(goalId: 1, percent: 20, day: "2026-11-14")
        #expect(store.progress(now: utcDate(2026, 11, 15, 5, 30), calendar: fixedCalendar("America/Denver")) == [1: 20])
    }

    @Test func markFiredIsTestAndSet() {
        let store = GoalProgressStore(defaults: freshDefaults(#function))
        #expect(!store.hasFired("goal.1.p50", onDay: "2026-11-14"))
        #expect(store.markFired("goal.1.p50", onDay: "2026-11-14") == true)
        #expect(store.markFired("goal.1.p50", onDay: "2026-11-14") == false)
        #expect(store.hasFired("goal.1.p50", onDay: "2026-11-14"))
        #expect(!store.hasFired("goal.1.p50", onDay: "2026-11-15"), "dedup resets each day")
        #expect(!store.hasFired("goal.1.p60", onDay: "2026-11-14"))
    }

    @Test func pruneRemovesKeysOlderThanTwoDays() {
        let defaults = freshDefaults(#function)
        let store = GoalProgressStore(defaults: defaults)
        for day in ["2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13", "2026-11-14"] {
            store.recordProgress(goalId: 1, percent: 10, day: day)
            store.markFired("goal.1.p10", onDay: day)
        }
        defaults.set("keep me", forKey: "nudge.user.firstName")

        store.prune(keepingDaysFrom: utcDate(2026, 11, 14), calendar: fixedCalendar("UTC"))

        #expect(store.progress(onDay: "2026-11-11").isEmpty)
        #expect(!store.hasFired("goal.1.p10", onDay: "2026-11-11"))
        #expect(defaults.object(forKey: "nudge.progress.2026-11-10") == nil)
        #expect(store.progress(onDay: "2026-11-12") == [1: 10])
        #expect(store.progress(onDay: "2026-11-14") == [1: 10])
        #expect(store.hasFired("goal.1.p10", onDay: "2026-11-12"))
        #expect(defaults.string(forKey: "nudge.user.firstName") == "keep me", "prune must not touch other keys")
    }

    @Test func pruneRemovesMalformedDayKeys() {
        let defaults = freshDefaults(#function)
        defaults.set(Data(), forKey: "nudge.progress.garbage")
        GoalProgressStore(defaults: defaults).prune(keepingDaysFrom: utcDate(2026, 11, 14), calendar: fixedCalendar("UTC"))
        #expect(defaults.object(forKey: "nudge.progress.garbage") == nil)
    }

    @Test func corruptProgressReadsAsEmpty() {
        let defaults = freshDefaults(#function)
        defaults.set(Data("nope".utf8), forKey: AppGroupKeys.progressKey(day: "2026-11-14"))
        let store = GoalProgressStore(defaults: defaults)
        #expect(store.progress(onDay: "2026-11-14").isEmpty)
        store.recordProgress(goalId: 1, percent: 10, day: "2026-11-14")
        #expect(store.progress(onDay: "2026-11-14") == [1: 10])
    }
}

// MARK: - Threshold routing (extension decision logic)

@Suite("Goals core — ThresholdRouter")
@MainActor
struct ThresholdRouterTests {

    private let day = "2026-11-14"
    private let catalog = [
        summary(id: 7, type: .app, limit: 1800, label: "Instagram"),
        MonitoringPlan.sessionTimeoutSummary(minutes: 45)
    ]

    @Test func lowMilestoneRecordsProgressOnly() {
        let store = GoalProgressStore(defaults: freshDefaults(#function))
        let outcome = ThresholdRouter.route(eventName: "goal.7.p30", catalog: catalog, store: store, day: day)
        #expect(outcome == .milestone(goal: catalog[0], percent: 30))
        #expect(store.progress(onDay: day) == [7: 30])
        #expect(store.hasFired("goal.7.p30", onDay: day))
    }

    @Test func p100IsGoalReached() {
        let store = GoalProgressStore(defaults: freshDefaults(#function))
        let outcome = ThresholdRouter.route(eventName: "goal.7.p100", catalog: catalog, store: store, day: day)
        #expect(outcome == .goalReached(goal: catalog[0]))
        #expect(store.progress(onDay: day) == [7: 100])
    }

    @Test func secondFireSameDayIsDuplicate() {
        let store = GoalProgressStore(defaults: freshDefaults(#function))
        _ = ThresholdRouter.route(eventName: "goal.7.p100", catalog: catalog, store: store, day: day)
        let again = ThresholdRouter.route(eventName: "goal.7.p100", catalog: catalog, store: store, day: day)
        #expect(again == .duplicate(eventName: "goal.7.p100"))
    }

    @Test func fireOnNextDayIsNotDuplicate() {
        let store = GoalProgressStore(defaults: freshDefaults(#function))
        _ = ThresholdRouter.route(eventName: "goal.7.p100", catalog: catalog, store: store, day: day)
        let next = ThresholdRouter.route(eventName: "goal.7.p100", catalog: catalog, store: store, day: "2026-11-15")
        #expect(next == .goalReached(goal: catalog[0]))
    }

    @Test func sessionTimeoutIsDedupedToo() {
        let store = GoalProgressStore(defaults: freshDefaults(#function))
        #expect(ThresholdRouter.route(eventName: "session.timeout", catalog: catalog, store: store, day: day)
                == .sessionTimeout(catalog[1]))
        #expect(ThresholdRouter.route(eventName: "session.timeout", catalog: catalog, store: store, day: day)
                == .duplicate(eventName: "session.timeout"))
    }

    @Test func unknownGoalIsUnmatchedAndNotMarked() {
        let store = GoalProgressStore(defaults: freshDefaults(#function))
        #expect(ThresholdRouter.route(eventName: "goal.99.p50", catalog: catalog, store: store, day: day)
                == .unmatched(eventName: "goal.99.p50"))
        #expect(!store.hasFired("goal.99.p50", onDay: day))
        #expect(store.progress(onDay: day).isEmpty)
    }

    @Test func junkNameIsUnmatched() {
        let store = GoalProgressStore(defaults: freshDefaults(#function))
        #expect(ThresholdRouter.route(eventName: "total", catalog: catalog, store: store, day: day)
                == .unmatched(eventName: "total"))
    }

    @Test func sessionTimeoutWithoutSummaryIsUnmatched() {
        let store = GoalProgressStore(defaults: freshDefaults(#function))
        #expect(ThresholdRouter.route(eventName: "session.timeout", catalog: [catalog[0]], store: store, day: day)
                == .unmatched(eventName: "session.timeout"))
    }
}

// MARK: - NudgeMessages per target type

@Suite("Goals core — NudgeMessages")
@MainActor
struct GoalsCoreMessageTests {

    @Test func reportForAppGoal() {
        let msg = NudgeMessages.reportForGoal(userName: "Josh", goalSummary: summary(id: 1, type: .app, limit: 1800, label: "Instagram"))
        #expect(msg == "Josh just hit their 30-minute limit on Instagram.")
    }

    @Test func reportForCategoryGoal() {
        let msg = NudgeMessages.reportForGoal(userName: "Josh", goalSummary: summary(id: 1, type: .category, limit: 3600, label: "Social"))
        #expect(msg == "Josh just hit their 60-minute limit on Social.")
    }

    @Test func reportForTotalGoal() {
        let msg = NudgeMessages.reportForGoal(userName: "Josh", goalSummary: summary(id: 1, type: .total, limit: 7200))
        #expect(msg == "Josh just hit their 120-minute daily screen time limit.")
    }

    @Test func reportForSessionTimeout() {
        let msg = NudgeMessages.reportForGoal(userName: "Josh", goalSummary: MonitoringPlan.sessionTimeoutSummary(minutes: 45))
        #expect(msg == "Josh has been on their phone for 45 minutes.")
    }

    /// Event names no longer carry the target type (goal.<id>.pNN), so the report must
    /// come from `targetType` — an app goal must not fall through to the "total" copy.
    @Test func reportIgnoresEventNameShape() {
        let msg = NudgeMessages.reportForGoal(userName: "Josh", goalSummary: summary(id: 1, type: .app, limit: 600, label: "TikTok"))
        #expect(msg.contains("TikTok"))
    }

    @Test func limitReachedNotificationCopy() {
        #expect(NudgeMessages.limitReachedTitle(label: "Instagram") == "You've hit your Instagram limit")
        #expect(NudgeMessages.limitReachedBody(label: "Instagram", limitSeconds: 5400)
                == "You set a 1h 30m daily limit on Instagram.")
    }
}

// MARK: - GoalService mapping

@Suite("Goals core — GoalService summary mapping")
@MainActor
struct GoalSummaryMappingTests {

    private func row(_ json: String) throws -> GoalSummaryRow {
        try JSONDecoder().decode(GoalSummaryRow.self, from: json.data(using: .utf8)!)
    }

    @Test func appGoalUsesLabelAndOwnSelection() throws {
        let selection = Data([1, 2, 3]).base64EncodedString()
        let s = try row("""
        { "id": 3, "limit_seconds": 1800, "frequency": "daily", "target_type": "app",
          "category_id": null, "selection": "\(selection)", "label": "Instagram",
          "start_date": null, "end_date": null, "app_category": null }
        """).toGoalSummary()
        #expect(s.goalId == 3)
        #expect(s.eventName == "goal.3")
        #expect(s.targetType == .app)
        #expect(s.targetLabel == "Instagram")
        #expect(s.selectionData == Data([1, 2, 3]))
        #expect(s.frequency == .daily)
    }

    @Test func categoryGoalUsesCategoryNameAndSelection() throws {
        let selection = Data([4, 5]).base64EncodedString()
        let s = try row("""
        { "id": 4, "limit_seconds": 3600, "frequency": "daily", "target_type": "category",
          "category_id": 9, "selection": null, "label": null,
          "start_date": "2026-11-01", "end_date": "2026-11-30",
          "app_category": { "name": "Social", "selection": "\(selection)" } }
        """).toGoalSummary()
        #expect(s.targetLabel == "Social")
        #expect(s.selectionData == Data([4, 5]))
        #expect(s.startDate == "2026-11-01")
        #expect(s.endDate == "2026-11-30")
    }

    @Test func totalGoalIsAllAppsWithNoSelection() throws {
        let s = try row("""
        { "id": 5, "limit_seconds": 7200, "frequency": "weekly", "target_type": "total",
          "category_id": null, "selection": null, "label": null,
          "start_date": null, "end_date": null, "app_category": null }
        """).toGoalSummary()
        #expect(s.targetLabel == "All Apps")
        #expect(s.selectionData == nil)
        #expect(s.frequency == .weekly)
    }

    @Test func invalidBase64SelectionMapsToNilData() throws {
        let s = try row("""
        { "id": 6, "limit_seconds": 60, "frequency": "daily", "target_type": "app",
          "category_id": null, "selection": "%%%", "label": "X",
          "start_date": null, "end_date": null, "app_category": null }
        """).toGoalSummary()
        #expect(s.selectionData == nil)
    }
}

// MARK: - goalDidChange debounce

private struct LoadFailed: Error {}

@MainActor
private final class StubInputsLoader: MonitoringInputsLoading {
    var calls = 0
    var result: Result<MonitoringInputs, Error> = .success(MonitoringInputs(goals: [], sessionTimeoutMinutes: nil))

    func loadMonitoringInputs() async throws -> MonitoringInputs {
        calls += 1
        return try result.get()
    }
}

@Suite("Goals core — goalDidChange debounce")
@MainActor
struct GoalDidChangeTests {

    /// Cancellation-aware sleeper that never actually waits.
    private let instantSleep: @Sendable (Duration) async throws -> Void = { _ in try Task.checkCancellation() }

    @Test func debounceIsOnePointFiveSeconds() {
        #expect(MonitoringRegistrationService.goalChangeDebounce == .milliseconds(1500))
    }

    @Test func rapidCallsCoalesceIntoOneRegistration() async {
        let loader = StubInputsLoader()
        var applied: [MonitoringInputs] = []
        let service = MonitoringRegistrationService(
            inputsLoader: loader, debounce: .seconds(1), sleep: instantSleep, apply: { applied.append($0) }
        )

        service.goalDidChange()
        service.goalDidChange()
        service.goalDidChange()
        await service.waitForPendingGoalChange()

        #expect(loader.calls == 1)
        #expect(applied.count == 1)
    }

    @Test func callsAfterCompletionRegisterAgain() async {
        let loader = StubInputsLoader()
        var applied = 0
        let service = MonitoringRegistrationService(
            inputsLoader: loader, debounce: .seconds(1), sleep: instantSleep, apply: { _ in applied += 1 }
        )

        service.goalDidChange()
        await service.waitForPendingGoalChange()
        service.goalDidChange()
        await service.waitForPendingGoalChange()

        #expect(applied == 2)
    }

    /// ADR-055: a failed fetch must never re-register.
    @Test func failedFetchNeverRegisters() async {
        let loader = StubInputsLoader()
        loader.result = .failure(LoadFailed())
        var applied = 0
        let service = MonitoringRegistrationService(
            inputsLoader: loader, debounce: .seconds(1), sleep: instantSleep, apply: { _ in applied += 1 }
        )

        service.goalDidChange()
        await service.waitForPendingGoalChange()

        #expect(loader.calls == 1)
        #expect(applied == 0)
    }

    @Test func passesFetchedInputsThrough() async {
        let loader = StubInputsLoader()
        let inputs = MonitoringInputs(goals: [summary(id: 3)], sessionTimeoutMinutes: 20)
        loader.result = .success(inputs)
        var applied: [MonitoringInputs] = []
        let service = MonitoringRegistrationService(
            inputsLoader: loader, debounce: .seconds(1), sleep: instantSleep, apply: { applied.append($0) }
        )

        service.goalDidChange()
        await service.waitForPendingGoalChange()

        #expect(applied == [inputs])
    }

    @Test func waitsForTheDebounceInterval() async {
        var requested: [Duration] = []
        let loader = StubInputsLoader()
        let service = MonitoringRegistrationService(
            inputsLoader: loader, debounce: .milliseconds(1500),
            sleep: { requested.append($0) }, apply: { _ in }
        )
        service.goalDidChange()
        await service.waitForPendingGoalChange()
        #expect(requested == [.milliseconds(1500)])
    }
}
